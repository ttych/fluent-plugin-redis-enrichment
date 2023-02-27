# frozen_string_literal: true

#
# Copyright 2022- Thomas Tych
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# THIS IS STRONGLY INSPIRATED/COPIED FROM OFFICIAL FLUENTD
# source for expand part is from record_transformer plugins

require 'connection_pool'
require 'redis'
require 'lru_redux'

require 'fluent/plugin/filter'

module Fluent
  module Plugin
    # filter plugin
    #   enrich record based on redis fetched content
    class RedisEnrichmentFilter < Fluent::Plugin::Filter
      Fluent::Plugin.register_filter('redis_enrichment', self)

      DEFAULT_REDIS_HOST = '127.0.0.1'
      DEFAULT_REDIS_PORT = 6379
      DEFAULT_REDIS_DB = 0
      DEFAULT_REDIS_PASSWORD = nil
      DEFAULT_REDIS_TIMEOUT = 5.0
      DEFAULT_REDIS_POOL = 5
      DEFAULT_SENTINELS = nil
      DEFAULT_SENTINEL_MASTER = 'mymaster'
      DEFAULT_SENTINEL_PASSWORD = nil
      DEFAULT_REDIS_ROLE = :slave
      DEFAULT_SENTINEL_PORT = 26_379
      DEFAULT_CACHE_TTL = 30 * 60
      DEFAULT_CACHE_SIZE = 5000
      DEFAULT_CACHE_TYPE = :lazy

      desc 'Redis host'
      config_param :redis_host, :string, default: DEFAULT_REDIS_HOST
      desc 'Redis port'
      config_param :redis_port, :integer, default: DEFAULT_REDIS_PORT
      desc 'Redis db id to select'
      config_param :redis_db, :integer, default: DEFAULT_REDIS_DB
      desc 'Redis password'
      config_param :redis_password, :string, default: DEFAULT_REDIS_PASSWORD, secret: true
      desc 'Redis timeout'
      config_param :redis_timeout, :float, default: DEFAULT_REDIS_TIMEOUT
      desc 'Redis connection pool'
      config_param :redis_pool, :integer, default: DEFAULT_REDIS_POOL
      desc 'Sentinels list (host:port,host:port,...)'
      config_param :sentinels, :array, default: DEFAULT_SENTINELS
      desc 'Sentinel password'
      config_param :sentinel_password, :string, default: DEFAULT_SENTINEL_PASSWORD, secret: true
      desc 'Sentinel redis master name'
      config_param :sentinel_master, :string, default: DEFAULT_SENTINEL_MASTER
      desc 'Sentinel redis role'
      config_param :redis_role, :enum, list: %i[master slave replica], default: DEFAULT_REDIS_ROLE

      desc 'local Cache type'
      config_param :cache_type, :enum, list: %i[lazy full no], default: DEFAULT_CACHE_TYPE
      desc 'local Cache size'
      config_param :cache_size, :integer, default: DEFAULT_CACHE_SIZE
      desc 'local Cache ttl'
      config_param :cache_ttl, :integer, default: DEFAULT_CACHE_TTL

      desc 'Redis key to fetch'
      config_param :key, :string, default: nil

      attr_reader :record_enrichment

      def configure(conf)
        super

        if !key || key.empty?
          raise Fluent::ConfigError,
                "key can't be empty, the value will be expanded to a redis key"
        end

        @record_enrichment = {}
        conf.elements.select { |element| element.name == 'record' }.each do |element|
          element.each_pair do |k, v|
            element.has_key?(k)
            @record_enrichment[k] = parse_record_value(v)
          end
        end

        @placeholder_expander = PlaceholderExpander.new(log)
      end

      def start
        super

        @redis = RedisPool.new(log: log, **redis_options)
        @cache = Cache.new(redis: @redis, log: log, **cache_options)
      end

      def shutdown
        @redis.quit
        @cache.clean

        super
      end

      def filter(tag, time, record)
        new_record = record.dup
        expanded_key = @placeholder_expander.expand(@key, { tag: tag,
                                                            time: time,
                                                            record: new_record })
        log.debug("filter_redis_enrichment: on tag:#{tag}, search #{expanded_key}")
        redis = @cache.get(expanded_key)
        new_record_record_enrichment = @placeholder_expander.expand(@record_enrichment,
                                                                    { tag: tag,
                                                                      time: time,
                                                                      record: new_record,
                                                                      redis: redis })
        new_record.merge(new_record_record_enrichment)
      end

      def cache_options
        {
          type: cache_type,
          size: cache_size,
          ttl: cache_ttl
        }
      end

      def redis_options
        redis_options = {
          db: redis_db,
          password: redis_password,
          timeout: redis_timeout,
          pool_size: redis_pool
        }

        if sentinels
          formated_sentinels = sentinels.map do |sentinel|
            host, port = sentinel.split(':')
            port = (port || DEFAULT_SENTINEL_PORT).to_i
            formated = { host: host, port: port }
            formated[:password] = sentinel_password if sentinel_password
            formated
          end
          redis_options.update({
                                 sentinels: formated_sentinels,
                                 name: sentinel_master,
                                 role: redis_role
                               })
        else
          redis_options.update({
                                 host: redis_host,
                                 port: redis_port
                               })
        end
      end

      private

      def parse_record_value(value_str)
        if value_str.start_with?('{', '[')
          JSON.parse(value_str)
        else
          value_str
        end
      rescue StandardError => e
        log.warn "failed to parse #{value_str} as json. Assuming #{value_str} is a string", error: e
        value_str # emit as string
      end

      module Cache
        def self.new(redis:, type: DEFAULT_CACHE_TYPE, size: DEFAULT_CACHE_SIZE, ttl: DEFAULT_CACHE_TTL, log: nil)
          klass = case type
                  when :lazy then LazyCache
                  when :full then FullCache
                  else
                    NoCache
                  end
          klass.new(redis: redis, size: size, ttl: ttl, log: log)
        end

        class NoCache
          attr_reader :log

          def initialize(redis:, size: nil, ttl: nil, log: nil)
            @redis = redis
            @size = size
            @ttl = ttl
            @log = log
          end

          def get(key)
            @redis.get(key)
          end

          def clean; end
        end

        class LazyCache < NoCache
          def initialize(redis:, size: DEFAULT_CACHE_SIZE, ttl: DEFAULT_CACHE_TTL, log: nil)
            super
          end

          def get(key)
            cache.getset(key) { @redis.get(key) }
          end

          def cache
            @cache ||= LruRedux::TTL::ThreadSafeCache.new(@size, @ttl)
          end
        end

        class FullCache < NoCache
          def initialize(*args, **kwargs)
            super

            initialize_cache
          end

          def initialize_cache
            @cache = {}
            @cache_mutex = Mutex.new

            reload
            @timer = timer(@ttl, &method(:reload))
          end

          def reload
            log.warn :RELOAD if log
            new_cache_content = @redis.get_all
            @cache_mutex.synchronize { @cache.replace(new_cache_content) }
          end

          def get(key)
            @cache_mutex.synchronize { @cache[key] }
          end

          def timer(interval, &block)
            Thread.new do
              loop do
                begin
                  sleep interval
                  block.call
                rescue StandardError => e
                  log.warn(e) if log
                end
              end
            end
          end

          def clean
            @timer.exit if @timer
          end
        end
      end

      # proxy for Redis client
      #   allow extract caching of cache
      class RedisPool
        attr_reader :log

        def initialize(sentinels: DEFAULT_SENTINELS, name: DEFAULT_SENTINEL_MASTER, role: DEFAULT_REDIS_ROLE,
                       host: DEFAULT_REDIS_HOST, port: DEFAULT_REDIS_PORT, db: DEFAULT_REDIS_DB,
                       password: DEFAULT_REDIS_PASSWORD, timeout: DEFAULT_REDIS_TIMEOUT, pool_size: DEFAULT_REDIS_POOL,
                       log: nil)
          @sentinels = sentinels
          @name = name
          @role = role
          @host = host
          @port = port
          @db = db
          @password = password
          @timeout = timeout
          @pool_size = pool_size
          @log = log
        end

        def get(key)
          return if key.nil?

          key_type = redis.type(key)
          case key_type
          when 'none' then nil
          when 'string' then redis.get(key)
          when 'hash' then redis.hgetall(key)
          else
            log.warn("redis key '#{key}' has an unmanaged type '#{key_type}'") if log
            nil
          end
        end

        def get_all
          redis.scan_each.with_object({}) do |key, all|
            case @redis.type(key)
            when 'hash' then all[key] = @redis.hgetall(key)
            when 'string' then all[key] = @redis.get(key)
            when 'set' then all[key] = @redis.smembers(key)
            end
          end
        end

        def quit
          redis.quit
        end

        private

        def redis
          @redis ||= ConnectionPool::Wrapper.new(size: @pool_size, timeout: @timeout) do
            if @sentinels
              Redis.new(sentinels: @sentinels, name: @name, role: @role, db: @db, password: @password,
                        timeout: @timeout)
            else
              Redis.new(host: @host, port: @port, db: @db, password: @password, timeout: @timeout)
            end
          end
        end
      end

      # The expand recurse loop
      # from record_transformer filter plugin
      class PlaceholderExpander
        def initialize(log)
          @log = log
          @cleanroom_expander = CleanroomExpander.new(log)
        end

        def expand(value, context = {})
          new_value = nil
          case value
          when String
            num_placeholders = value.scan('${').size
            if num_placeholders == 1 && value.start_with?('${') && value.end_with?('}')
              new_value = value[2..-2] # ${..} => ..
            end
            new_value ||= "%Q[#{value.gsub('${', '#{')}]"
            new_value = @cleanroom_expander.expand(new_value, **context)
          when Hash
            new_value = {}
            value.each_pair do |k, v|
              new_value[expand(k, context)] = expand(v, context)
            end
          when Array
            new_value = []
            value.each_with_index do |v, i|
              new_value[i] = expand(v, context)
            end
          else
            new_value = value
          end

          new_value
        end
      end

      # safer object to eval code
      # from record_transformer filter plugin
      class CleanroomExpander
        attr_reader :log

        def initialize(log)
          @log = log
        end

        def expand(__str_to_eval__, tag: nil, time: nil, record: nil, redis: nil, **_extra)
          instance_eval(__str_to_eval__)
        rescue NoMethodError => e
          log.warn("while expanding #{__str_to_eval__}: #{e}")
          nil
        rescue StandardError => e
          log.warn("while expanding #{__str_to_eval__}: #{e}")
          nil
        end

        Object.instance_methods.each do |m|
          unless m.to_s =~ /^__|respond_to_missing\?|object_id|public_methods|instance_eval|method_missing|define_singleton_method|respond_to\?|new_ostruct_member|^class$/
            undef_method m
          end
        end
      end
    end
  end
end
