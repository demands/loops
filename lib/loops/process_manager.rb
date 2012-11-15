module Loops
  class ProcessManager
    attr_reader :logger

    def initialize(config, logger)
      @config = {
        'poll_period' => 1,
        'wait_period' => 10,
        'workers_engine' => 'fork',
      }.merge(config)

      @logger = logger
      @worker_pools = {}
      @shutdown = false
      @reopen_logs = false
    end

    def update_wait_period(period)
      return unless period
      @config['wait_period'] = [@config['wait_period'], period].max
    end

    def start_workers(name, number, &blk)
      raise ArgumentError, "Need a worker block!" unless block_given?

      logger.debug("Creating a workers pool of #{number} workers for #{name} loop...")
      @worker_pools[name] = Loops::WorkerPool.new(name, self, @config['workers_engine'], &blk)
      @worker_pools[name].start_workers(number)
    end

    def monitor_workers
      setup_signals

      logger.info('Starting workers monitoring code...')
      loop do
        logger.debug("Checking workers' health...")
        @worker_pools.each do |name, pool|
          break if shutdown?
          reopen_worker_logs if reopen_logs?
          pool.check_workers
        end

        break if shutdown?
        reopen_worker_logs if reopen_logs?
        logger.debug("Sleeping for #{@config['poll_period']} seconds...")
        sleep(@config['poll_period'])
      end
    ensure
      logger.info("Workers monitoring loop is finished, starting shutdown...")
      # Send out stop signals
      stop_workers(false)

      # Wait for all the workers to die
      unless wait_for_workers(@config['wait_period'])
        logger.info("Some workers are still alive after 10 seconds of waiting. Killing them...")
        stop_workers(true)
        wait_for_workers(5)
      end
    end

    def setup_signals
      # Zombie reapers
      trap('CHLD') {}
      trap('EXIT') {}
    end

    def wait_for_workers(seconds)
      seconds.times do
        logger.info("Shutting down... waiting for workers to die (we have #{seconds} seconds)...")
        running_total = 0

        @worker_pools.each do |name, pool|
          running_total += pool.wait_workers
        end

        if running_total.zero?
          logger.info("All workers are dead. Exiting...")
          return true
        end

        logger.info("#{running_total} workers are still running! Sleeping for a second...")
        sleep(1)
      end

      return false
    end

    def stop_workers(force = false)
      # Set shutdown flag
      logger.info("Stopping workers#{force ? ' (forced)' : ''}...")

      # Termination loop
      @worker_pools.each do |name, pool|
        pool.stop_workers(force)
      end
    end

    def reopen_worker_logs
      logger.warn("Reopening worker logs!")
      @worker_pools.each do |_, pool|
        pool.reopen_worker_logs
      end
      @reopen_logs = false
    end

    def shutdown?
      @shutdown
    end

    def reopen_logs?
      @reopen_logs
    end

    def start_shutdown!
      logger.info("Starting shutdown (shutdown flag set)...")
      @shutdown = true
    end

    def start_reopen_logs!
      # logger.reopen_logs!
      @reopen_logs = true
    end
  end
end
