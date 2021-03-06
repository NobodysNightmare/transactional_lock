require 'transactional_lock/configuration'

module TransactionalLock
  class LockAcquireError < StandardError
  end

  class LockConflict < LockAcquireError
    def initialize(new_lock, old_lock)
      super("Can't acquire lock '#{new_lock.name}'. Need to release lock '#{old_lock.name}' first.")
    end
  end

  # Represents a database advisory lock.
  # N.B. currently quite MySQL specific, except that its interface allows more than one active lock
  # MySQL will only ever support one lock at a time (releasing earlier locks implicitly)
  class AdvisoryLock
    def self.acquired_locks
      @acquired_locks ||= []
      @acquired_locks.dup.freeze
    end

    def self.push_lock(lock)
      @acquired_locks ||= []
      @acquired_locks << lock
    end

    def self.delete_lock(lock)
      @acquired_locks ||= []
      @acquired_locks.delete(lock)
    end

    def self.forget_locks!
      @acquired_locks = []
    end

    attr_reader :name, :timeout

    def initialize(name, timeout: ::TransactionalLock::Configuration.default_timeout)
      @name = name
      @timeout = timeout
      @acquired = false
    end

    def acquire
      return if already_locked?
      check_for_lock_conflicts!

      result = ActiveRecord::Base.connection.execute(
                 "SELECT GET_LOCK('#{sql_name}', #{sql_timeout})")

      unless result.first.first == 1
        raise LockAcquireError.new "Could not acquire lock '#{@name}'."
      end

      self.class.push_lock(self)
    end

    def release
      ActiveRecord::Base.connection.execute("SELECT RELEASE_LOCK('#{sql_name}')")
    ensure
      # In any case consider this lock being released (avoiding inability for new acquires)
      self.class.delete_lock(self)
    end

    private

    def already_locked?
      self.class.acquired_locks.any? { |lock| lock.name == name }
    end

    def check_for_lock_conflicts!
      conflict_lock = self.class.acquired_locks.detect { |lock| lock.name != name }
      if conflict_lock
        raise LockConflict.new self, conflict_lock
      end
    end

    def sql_name
      ActiveRecord::Base.connection.quote_string(@name)
    end

    def sql_timeout
      Integer(@timeout)
    end
  end
end
