require 'json'
module Patriot
  module JobStore

    # a JobStore implementation on RDB
    class RDBJobStore < Patriot::JobStore::Base

      # default  priority
      DEFAULT_PRIORITY=1 #  TODO move to Patriot::JobStore of core

      ####  Tables
      # job definition table
      JOB_TABLE      = 'jobs'
      # dependency relation table
      FLOW_TABLE     = 'flows'
      # job and produced product table
      PRODUCER_TABLE = 'producers'
      # job and required product table
      CONSUMER_TABLE = 'consumers'
      # table for execution history
      HISTORY_TABLE  = 'job_histories'

      # date format of execution history
      DATE_FORMAT = "%Y-%m-%d %H:%M:%S"

      # attributes included in job_ticket
      TICKET_COLUMNS = ['job_id', 'update_id', 'node']
      # all columns of the job table
      ALL_COLUMNS    = [:id,
                        :job_id,
                        :job_def_id,
                        :update_id,
                        :state,
                        :content,
                        :start_after,
                        :node,
                        :host,
                        :priority]
      # mapping from command attributes to table columns
      ATTR_TO_COLUMN = {Patriot::Command::STATE_ATTR          => :state,
                        Patriot::Command::PRIORITY_ATTR       => :priority,
                        Patriot::Command::START_DATETIME_ATTR => :start_after,
                        Patriot::Command::EXEC_NODE_ATTR      => :node,
                        Patriot::Command::EXEC_HOST_ATTR      => :host}

      include Patriot::Util::DBClient
      include Patriot::Util::Logger
      include Patriot::Util::Retry

      # @see Patriot::JobStore::Base#initialize
      def initialize(store_id, config)
        @config = config
        prefix = [Patriot::JobStore::CONFIG_PREFIX, store_id].join(".")
        @db_config = read_dbconfig(prefix, config)
        @logger = create_logger(config)
        @initiator_id = connect(@db_config){|c| c.select(JOB_TABLE, {:job_id => Patriot::JobStore::INITIATOR_JOB_ID})[0].to_hash[:id] }
      end

      # @see Patriot::JobStore::Base#register
      def register(update_id, jobs)
        jobs = [jobs] unless jobs.is_a? Array
        jobs.each{|job| raise "#{job.job_id} is not acceptable" unless acceptable?(job) }
        @logger.info "start to register jobs"
        connect(@db_config) do |c|
          jobs.each{|job| _upsert_job(update_id, job, c)}
          c.update(JOB_TABLE,
                   {:state => Patriot::JobStore::JobState::WAIT},
                   {:state => Patriot::JobStore::JobState::INIT, :update_id => update_id}
                  )
        end
        @logger.info "job registration finished"
      end

      def _upsert_job(update_id, job, c)
        new_vals = {:job_id => job.job_id, :priority => DEFAULT_PRIORITY}
        new_vals[:update_id] = update_id unless update_id.nil?
        job_attr = job.attributes.dup
        # extract and remove command attributes
        requisites = job_attr.delete(Patriot::Command::REQUISITES_ATTR) || []
        products   = job_attr.delete(Patriot::Command::PRODUCTS_ATTR)   || []

        prev_vals = c.select(JOB_TABLE, {:job_id => job.job_id})
        ATTR_TO_COLUMN.each do |a,c|
          val = job_attr.delete(a)
          next if val.nil? && c == :state
          val = val.strftime(DATE_FORMAT) if !val.nil? && a == Patriot::Command::START_DATETIME_ATTR
          new_vals[c] = val
        end
        # serialize remaining attributes
        new_vals[:content] = JSON.generate(job_attr)

        if prev_vals.empty?
          raise "update_id should not be nil for new jobs" if new_vals[:update_id].nil?
          new_vals[:state] ||= Patriot::JobStore::JobState::INIT # set default state
          serial_id = c.insert(JOB_TABLE, new_vals)
        elsif prev_vals.size == 1
          serial_id = prev_vals[0].to_hash[:id]
          c.update(JOB_TABLE, new_vals, {:job_id => job.job_id})
        end

        raise "failed to upsert a job #{j}" if serial_id.nil?

        _update_dependency(serial_id, requisites, CONSUMER_TABLE, c)
        _update_dependency(serial_id, products,   PRODUCER_TABLE, c)
        # set dependency for initiator jobs
        c.insert(FLOW_TABLE, {:producer_id => @initiator_id, :consumer_id => serial_id}, {:ignore => true}) if requisites.empty?
      end
      private :_upsert_job

      def _update_dependency(serial_id, updated_products, updated_table, conn)
        raise "unknown dependency table #{updated_table}" unless [CONSUMER_TABLE, PRODUCER_TABLE].include?(updated_table)
        updated_col    = updated_table == CONSUMER_TABLE ? :consumer_id : :producer_id
        opposite_table = updated_table == CONSUMER_TABLE ? PRODUCER_TABLE  : CONSUMER_TABLE
        opposite_col   = updated_table == CONSUMER_TABLE ? :producer_id : :consumer_id

        # deleted dependency
        conn.select(updated_table, {:job_id => serial_id}).each do |u|
          unless updated_products.include?(u.product)
            conn.delete(updated_table, {:job_id => serial_id, :product => u.product})
            conn.delete(FLOW_TABLE,{updated_col=> serial_id})
          end
        end

        # added dependency
        updated_products.each do |product|
          conn.insert(updated_table, {:job_id => serial_id, :product => product}, {:ignore => true})
          conn.select(opposite_table, {:product => product}).each do |producer|
            conn.insert(FLOW_TABLE, {updated_col => serial_id, opposite_col => producer.job_id}, {:ignore => true})
          end
        end
      end
      private :_update_dependency

      # @see Patriot::JobStore::Base#acceptable?
      def acceptable?(job)
        begin
          json = JSON.generate(job.attributes)
        rescue Exception => e
          @logger.warn e
          return false
        end
        return true
      end

      # @see Patriot::JobStore::Base#get_job_tickets
      def get_job_tickets(host, nodes, options = {})
        nodes = [nodes] unless nodes.is_a?(Array)
        begin
          query = _generate_fetching_job_sql(host, nodes,options)
          @logger.debug "fetchings job by #{query}"
          connect(@db_config) do |c|
            return c.execute_statement(query).map{|r| Patriot::JobStore::JobTicket.new(r.job_id, r.update_id, r.node) }
          end
        rescue => e
          @logger.error e
          raise e
        end
      end

      def _generate_fetching_job_sql(host, nodes, options)
        node_condition = (nodes.map{|n| "c.node = '#{n}'" } | ["c.node IS NULL"]).join(" OR ")
        query          = <<"END_OB_QUERY"
          SELECT c.#{TICKET_COLUMNS[0]}, c.#{TICKET_COLUMNS[1]}, c.#{TICKET_COLUMNS[2]}
          FROM flows f
          JOIN jobs c on c.id = f.consumer_id
          JOIN jobs p on f.producer_id = p.id
          WHERE c.state=#{Patriot::JobStore::JobState::WAIT}
              AND (#{node_condition})
              AND (c.host = '#{host}' OR c.host IS NULL)
              AND c.content IS NOT NULL
              AND (c.start_after IS NULL  OR c.start_after < current_timestamp)
          GROUP BY f.consumer_id HAVING Min(p.state=#{Patriot::JobStore::JobState::SUCCEEDED})=1
          ORDER BY c.priority
END_OB_QUERY
        query = "#{query} LIMIT #{options[:fetch_limit]} " if options.has_key?(:fetch_limit)
        return query.gsub(/(\r|\n|\s+)/, ' ')
      end
      private :_generate_fetching_job_sql

      # @see Patriot::JobStore::Base#offer_to_execute
      def offer_to_execute(job_ticket)
        connect(@db_config) do |c|
          unless _check_and_set_state(job_ticket, Patriot::JobStore::JobState::WAIT, Patriot::JobStore::JobState::RUNNING, c)
            @logger.debug("execution of job: #{job_ticket.job_id} is skipped")
            return nil
          end
          execution_id = c.insert(HISTORY_TABLE,
                                 {:job_id     => job_ticket.job_id,
                                  :node       => job_ticket.exec_node,
                                  :host       => job_ticket.exec_host,
                                  :thread     => job_ticket.exec_thread,
                                  :begin_at   => Time.now.strftime(DATE_FORMAT)})
          record = c.select(JOB_TABLE, {:job_id => job_ticket.job_id})
          raise "duplicated entry found for #{job_ticket}" if record.size > 1
          raise "no entry found for #{job_ticket}" if record.empty?
          job = _record_to_job(record[0])
          begin
            return {:execution_id => execution_id, :command => job.to_command(@config)}
          rescue Exception => e
            marked = _check_and_set_state(job_ticket, Patriot::JobStore::JobState::RUNNING, Patriot::JobStore::JobState::FAILED, c)
            @logger.error "failed to create a command for #{job_ticket.job_id} (set to error? #{marked})"
            raise e
          end
        end
      end

      # @see Patriot::JobStore::Base#report_completion_status
      def report_completion_status(job_ticket)
        exit_code  = job_ticket.exit_code
        post_state = Patriot::JobStore::EXIT_CODE_TO_STATE[exit_code]
        raise "illegal exit_code #{exit_code}" if post_state.nil?
        connect(@db_config) do |c|
          if c.update(HISTORY_TABLE, {:end_at => Time.now.strftime(DATE_FORMAT), :exit_code => exit_code, :description => job_ticket.description}, {:id => job_ticket.execution_id}) != 1
            @logger.warn "illegal state of history for #{job_ticket.job_id}"
          end
          return _check_and_set_state(job_ticket, Patriot::JobStore::JobState::RUNNING, post_state, c)
        end
      end

      def _check_and_set_state(job_ticket, prev_state, post_state, conn)
        @logger.debug("changing state of #{job_ticket.job_id} from #{prev_state} to #{post_state}")
        condition = {:job_id => job_ticket.job_id, :state => prev_state, :update_id => job_ticket.update_id}
        num_updated = conn.update(JOB_TABLE, {:state => post_state}, condition)
        if num_updated == 0 # in case of job is redfined
          @logger.info("definition or state of job: #{job_ticket.job_id} is changed and its state is not changed")
          return false
        elsif num_updated != 1
          raise "illegal state: #{job_ticket.job_id} has more than #{num_updated} records"
        end
        return true
      end
      private :_check_and_set_state

      # @see Patriot::JobStore::Base#set_state
      def set_state(update_id, job_ids, new_state)
        raise "jobs are not selected" if job_ids.nil? || job_ids.empty?
        stmt = "UPDATE jobs SET state = #{new_state} WHERE #{job_ids.map{|jid| "job_id = '#{jid}'"}.join(" OR ")}"
        connect(@db_config){|c| c.execute_statement(stmt, :update)}
      end

      # @param  [String]  job_id  JOB ID
      # @return [Patriot::JobStore::Job]
      # @see Patriot::JobStore::Base#get_job
      def get_job(job_id)
        connect(@db_config) {|c| return _get_job(job_id, c)}
      end

      # @param  [String]  job_id  JOB ID
      # @param  [Patriot::Util::DBClient::Base] c
      # @return [Patriot::JobStore::Job]
      def _get_job(job_id, c)
        records = c.select(JOB_TABLE, {:job_id => job_id})
        return nil if records.empty?
        raise "duplicate job_ticket for #{job_id}" unless records.size == 1
        record = records[0]
        serial_id = record.to_hash[:id]
        job = _record_to_job(record)
        job[Patriot::Command::PRODUCTS_ATTR] = c.select(PRODUCER_TABLE, {:job_id => serial_id}).map{|r| r.product}
        job[Patriot::Command::REQUISITES_ATTR] = c.select(CONSUMER_TABLE, {:job_id => serial_id}).map{|r| r.product}
        return job
      end
      private :_get_job

      # @see Patriot::JobStore::Base#get_producers
      def get_producers(products, opts = {:include_attrs => [Patriot::Command::STATE_ATTR]})
        connect(@db_config) {|c| return _get_jobs_for_products(PRODUCER_TABLE, products, opts, c)}
      end

      # @see Patriot::JobStore::Base#get_producers
      def get_consumers(products, opts = {:include_attrs => [Patriot::Command::STATE_ATTR]})
        connect(@db_config) {|c| return _get_jobs_for_products(CONSUMER_TABLE, products, opts, c)}
      end

      def _get_jobs_for_products(table, products, opts = {:include_attrs => [Patriot::Command::STATE_ATTR]}, c)
        result = []
        return result if products.blank?
        products = [products] unless products.is_a? Array
        included_cols = (opts[:include_attrs] || []).map{|a| ATTR_TO_COLUMN[a]}

        products.each do |product|
          jids = c.select(table, {:product => product}).map{|r| r.job_id}
          next if jids.empty?
          included_cols = (['job_id'] | (included_cols || [])).uniq
          query = "SELECT #{included_cols.join(', ')} FROM jobs WHERE #{jids.map{|jid| "id = #{jid}" }.join(' OR ')}"
          c.execute_statement(query, :select).each do |r|
            result.push(r.to_hash)
          end
        end
        return result.uniq
      end
      private :_get_jobs_for_products

      # @param  [String]  job_id  JOB ID
      # @param  [Hash]    opts    options
      # @return [Hash]    histories
      def get_execution_history(job_id, opts = {})
        connect(@db_config) {|c| return _get_execution_history(job_id, opts, c)}
      end

      # @param  [String]  job_id  JOB ID
      # @param  [Hash]    opts    options
      # @param  [Patriot::Util::DBClient::Base] c
      # @return [Hash]    histories
      def _get_execution_history(job_id, opts, c)
        opts = {:limit => 1, :order => :DESC}.merge(opts)
        query = "SELECT * FROM #{HISTORY_TABLE} WHERE job_id = '#{job_id}' ORDER BY id #{opts[:order]} LIMIT #{opts[:limit]}"

        return c.execute_statement(query, :select).map(&:to_hash)
      end
      private :_get_execution_history

      # get nodes and edges information to render graph
      # @param  [String]  job_id  JOB ID
      # @param  [Hash]    opts    options
      # @return [Array]   [nodes, edges]
      def get_graph(job_id, opts = {})
        connect(@db_config) do |db_conn|
          job = _get_job(job_id, db_conn)

          job[:consumers] = _get_jobs_for_products(CONSUMER_TABLE, job[Patriot::Command::PRODUCTS_ATTR], opts, db_conn) || []
          job[:producers] = _get_jobs_for_products(PRODUCER_TABLE, job[Patriot::Command::REQUISITES_ATTR], opts, db_conn) || []
          history = _get_execution_history(job_id, {}, db_conn)[0]

          hashed_job = {
            :job_id => job.job_id,
            :history => history,
            :depth => 0
          }.merge(job.attributes)

          # set self node
          nodes = {job_id => hashed_job}
          edges = []

          _set_dependency(
            db_conn,
            :producers,
            opts[:producer_depth],
            nodes,
            edges,
            hashed_job
          )

          _set_dependency(
            db_conn,
            :consumers,
            opts[:consumer_depth],
            nodes,
            edges,
            hashed_job
          )

          return {:nodes => nodes, :edges => edges}
        end
      end

      # get dependency and set nodes and edges
      #
      # @private
      # @param  [Patriot::Util::DBClient::Base] db_conn
      # @param  [Symbol]  direction       :producers or :consumers
      # @param  [Integer] depth           dependency depth to get
      # @param  [Hash]    nodes           nodes to set for dager-d3
      # @param  [Array]   edges           edges to set for dager-d3
      # @param  [Hash]    base_job        base job to get dependency
      def _set_dependency(db_conn, direction, depth, nodes, edges, base_job)
        return if nodes[base_job[:job_id]][:depth] == depth

        base_job[direction].map{|depend_job|
          job = _get_job(depend_job[:job_id], db_conn)
          job[:consumers] = _get_jobs_for_products(CONSUMER_TABLE, job[Patriot::Command::PRODUCTS_ATTR], {}, db_conn) || []
          job[:producers] = _get_jobs_for_products(PRODUCER_TABLE, job[Patriot::Command::REQUISITES_ATTR], {}, db_conn) || []
          history = _get_execution_history(depend_job[:job_id], {}, db_conn)[0]

          hashed_job = {
            :job_id => job.job_id,
            :history => history,
            :depth => base_job[:depth] + 1
          }.merge(job.attributes)

          nodes[job.job_id] = hashed_job
          if direction == :producers
            edges.push([job.job_id, base_job[:job_id]])
          else
            edges.push([base_job[:job_id], job.job_id])
          end

          # call recursively
          _set_dependency(
            db_conn,
            direction,
            depth,
            nodes,
            edges,
            hashed_job
          )
        }
      end
      private :_set_dependency

      # @see Patriot::JobStore::Base#find_jobs_by_state
      def find_jobs_by_state(state, opts = {})
        raise "OFFSET is set WITHOUT LIMIT" if opts.has_key?(:offset) && !opts.has_key?(:limit)
        condition = ["state = #{state}", "id != #{@initiator_id}"]
        condition |= ["job_id LIKE '#{opts[:filter_exp]}'"] if opts.has_key?(:filter_exp)
        query = "SELECT job_id FROM jobs WHERE #{condition.join(' AND ')}"
        query = "#{query} ORDER BY job_id DESC"
        if opts.has_key?(:limit)
          query = "#{query} LIMIT #{opts[:limit]}"
          query = "#{query} OFFSET #{opts[:offset]}" if opts.has_key?(:offset)
        end
        connect(@db_config) do |c|
          return c.execute_statement(query, :select).map{|r| r.job_id }
        end
      end

      # @see Patriot::JobStore::Base#get_job_size
      def get_job_size(opts = {})
        opts  = {:ignore_states => []}.merge(opts)
        if opts[:ignore_states].empty?
          query = "SELECT state, count(1) size FROM jobs GROUP BY state"
        else
          query = "SELECT state, count(1) size FROM jobs WHERE #{opts[:ignore_states].map{|s| "state != #{s}" }.join(" AND ")} GROUP BY state"
        end
        sizes = {}
        connect(@db_config) do |c|
          c.execute_statement(query).each do |r|
            sizes[r.state] = r.size
            sizes[r.state] = sizes[r.state] - 1 if r.state == Patriot::JobStore::JobState::SUCCEEDED # ignore initiator
          end
        end
        return sizes
      end

      # @see Patriot::JobStore::Base#delete_job
      def delete_job(job_id)
        connect(@db_config) do |c|
          record = c.select(JOB_TABLE, {:job_id => job_id})
          return if record.nil? || record.empty?
          raise "illegal state: more than one records for #{job_id}" if record.size > 1
          serial_id = record[0].to_hash[:id]
          c.delete(CONSUMER_TABLE, {:job_id => serial_id})
          c.delete(PRODUCER_TABLE, {:job_id => serial_id})
          c.delete(FLOW_TABLE, {:consumer_id => serial_id})
          c.delete(FLOW_TABLE, {:producer_id => serial_id})
          c.delete(JOB_TABLE, {:job_id => job_id})
        end
      end

      def _record_to_job(record)
        job = Patriot::JobStore::Job.new(record.job_id)
        job.update_id = record.update_id
        ATTR_TO_COLUMN.each{|attr, col| job[attr] = record.send(col) }
        unless record.content.nil?
          content = JSON.parse(record.content, {:symbolize_names => true})
          content.each{|k,v| job[k] = v}
        end
        return job
      end
      private :_record_to_job
    end
  end
end
