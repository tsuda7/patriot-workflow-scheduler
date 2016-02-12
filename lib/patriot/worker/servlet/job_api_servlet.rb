require 'sinatra/base'
require 'sinatra/contrib'

module Patriot
  module Worker
    module Servlet
      # excepton thrown in case job not found
      class JobNotFoundException < Exception; end
      # provide job management functionalities
      class JobAPIServlet < Sinatra::Base
        register Sinatra::Contrib
        include Patriot::Util::DateUtil
        include Patriot::Command::Parser

        set :show_exceptions, :after_handler

        # @param worker [Patriot::Wokrer::Base]
        # @param config [Patriot::Util::Config::Base]
        def self.configure(worker, config)
          @@job_store = worker.job_store
          @@config = config
          @@username  = config.get(USERNAME_KEY, "")
          @@password  = config.get(PASSWORD_KEY, "")
        end

        ### Helper Methods
        helpers do
          # require authorization for updating
          def protected!
            return if authorized?
            headers['WWW-Authenticate'] = 'Basic Realm="Admin Only"'
            halt 401, "Not Authorized"
          end
          # authorize user (basic authentication)
          def authorized?
            @auth ||= Rack::Auth::Basic::Request.new(request.env)
            return @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials == [@@username, @@password]
          end
        end


        get '/' do
          state = params['state'] || Patriot::JobStore::JobState::FAILED
          query = {:limit  => params['limit']  || DEFAULT_JOB_LIMIT,
                   :offset => params['offset'] || DEFAULT_JOB_OFFSET}
          query[:filter_exp] = params['filter_exp'] if params.has_key?('filter_exp') && params['filter_exp'] != ""
          jobs = @@job_store.find_jobs_by_state(state.to_i, query)
          jobs ||= []
          return JSON.generate(jobs)
        end

        post '/' do
          # protected!
          body = JSON.parse(request.body.read)
          halt(400, json({ERROR: "COMMAND_CLASS is not provided"})) if body["COMMAND_CLASS"].blank?
          command_class = body.delete("COMMAND_CLASS").gsub(/\./, '::').constantize

          jobs = build_commands(command_class, body)

          @@job_store.register(Time.now.to_i, jobs)
          return JSON.generate({:jobs => jobs.map{|j| j.job_id}, :state => "INIT"})
        end

        def build_commands(clazz, params)
          _params = params.dup
          _params["target_datetime"] = Date.today
          cmd = clazz.new(@@config)
          cmd.produce(_params.delete("products")) unless _params["products"].nil?
          cmd.require(_params.delete("requisites")) unless _params["requisites"].nil?
          cmds = cmd.build(_params)
          return cmds.map{|c| c.to_job}
        end
        private :build_commands

        get '/stats' do
          return JSON.generate(@@job_store.get_job_size(:ignore_states => [Patriot::JobStore::JobState::SUCCEEDED]))
        end


        get '/:job_id' do
          job_id = params[:job_id]
          job = @@job_store.get(job_id, {:include_dependency => true})
          raise JobNotFoundException, job_id if job.nil?
          return JSON.generate(job.attributes.merge({'job_id' => job_id, "update_id" => job.update_id}))
        end

        put '/:job_id' do
          body = JSON.parse(request.body.read)

          job_id = params['job_id']
          state = body['state']
          set_state_of_jobs([job_id], state)
          return JSON.generate({"job_id" => job_id, "state" => state})
        end

        delete '/:job_id' do
          job_id = params['job_id']
          @@job_store.delete_job(job_id)
          return JSON.generate({"job_id" => job_id})
        end


        get '/:job_id/histories' do
          job_id = params[:job_id]
          history_size = params['size'] || 3
          histories = @@job_store.get_execution_history(job_id, {:limit => history_size})
          return JSON.generate(histories)
        end


        error JobNotFoundException do
          "Job #{env['sinatra.error'].message} is not found"
        end

        # @private
        def set_state_of_jobs(job_ids, state, opts = {})
          opts = {:include_subsequent => false}.merge(opts)
          update_id = Time.now.to_i
          @@job_store.set_state(update_id, job_ids, state)
          if opts[:include_subsequent]
            @@job_store.process_subsequent(job_ids) do |job_store, jobs|
              @@job_store.set_state(update_id, jobs.map(&:job_id), state)
            end
          end
        end
        private :set_state_of_jobs

        # @private
        def construct_time(exec_date, start_after)
          return nil if exec_date.blank? && start_after.blank?
          # set tomorrow as default
          date = (exec_date || (Date.today + 1).strftime("%Y-%m-%d")).split("-").map(&:to_i)
          # set midnight as default
          time = (start_after || "00:00:00").split(":").map(&:to_i)
          return Time.new(date[0], date[1], date[2], time[0], time[1], time[2])
        end
        private :construct_time

      end
    end
  end
end
