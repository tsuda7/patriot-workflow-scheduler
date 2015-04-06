require 'patriot/util/db_client/base'
require 'patriot/util/db_client/record'
require 'patriot/util/db_client/hash_record'

# don't load product-specific client
# should be loaded with plugin

module Patriot
  module Util
    module DBClient

      DB_CONFIG_KEYS = ["adapter", 
                        "database", 
                        "host", 
                        "port", 
                        "username", 
                        "password", 
                        "encoding", 
                        "pool"]

      def read_dbconfig(prefix, config)
        db_config = {}
        Patriot::Util::DBClient::DB_CONFIG_KEYS.each do |k|
          v = config.get([prefix,k].join("."))
          db_config[k.to_sym] = v
        end
        return db_config
      end

      # get connection to db.
      # if block is given, call the given block and close the connection
      # === Argument
      # [dbconf] 
      #   configuration for database in a Hash
      #   type of database should be set with key :adapter
      # [blk]
      #   block executed with a connection to the database. 
      #   the connection is passed to the block as a argument
      def connect(dbconf, &blk)
        client = get_db_client(dbconf)
        return client unless block_given?
        begin 
          return yield client
        rescue Exception => e
          raise e
        ensure 
          client.close
        end
      end

      def get_db_client(dbconf = {})
        raise "no adapter is specified" unless dbconf.has_key?(:adapter)
        adapter = dbconf[:adapter].to_sym
        raise "no builder method is registered for #{adapter}" unless self.respond_to?(adapter)
        return self.send(adapter, dbconf)
      end
      private :get_db_client

    end
  end
end
