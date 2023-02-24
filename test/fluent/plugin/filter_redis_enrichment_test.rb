# frozen_string_literal: true

require 'helper'
require 'fluent/plugin/filter_redis_enrichment'

class FakeRedis
  def initialize(data)
    @data = data
    @calls = []
  end

  def get(key)
    @calls.append([:get, key])
    @data[key]
  end

  def get_all
    @calls.append([:get_all])
    @data
  end

  attr_reader :calls

  def call_count
    @calls.size
  end
end

# test unit for RedisEnrichmentFilter
class RedisEnrichmentFilterTest < Test::Unit::TestCase
  setup do
    Fluent::Test.setup
  end

  sub_test_case 'configuration' do
    test 'missing key in configuration leads to error' do
      assert_raise(Fluent::ConfigError) do
        create_driver('')
      end
    end

    test 'empty configuration leads to default conf' do
      driver = create_driver('key abc')
      filter = driver.instance

      assert_equal('127.0.0.1', filter.redis_host)
      assert_equal(6379, filter.redis_port)
      assert_equal(0, filter.redis_db)
      assert_equal(nil, filter.redis_password)
      assert_equal(5.0, filter.redis_timeout)
      assert_equal(5, filter.redis_pool)
      assert_equal(nil, filter.sentinels)
      assert_equal(nil, filter.sentinel_password)
      assert_equal('mymaster', filter.sentinel_master)
      assert_equal(:slave, filter.redis_role)

      assert_equal('abc', filter.key)
    end

    test 'can inject all filter options' do
      conf = %(
        redis_host hostname.test
        redis_port 12345
        redis_db 6
        redis_password test_password
        redis_timeout 10
        redis_pool 3
        key test_key
      )
      driver = create_driver(conf)
      filter = driver.instance

      assert_equal('hostname.test', filter.redis_host)
      assert_equal(12_345, filter.redis_port)
      assert_equal(6, filter.redis_db)
      assert_equal('test_password', filter.redis_password)
      assert_equal(10.0, filter.redis_timeout)
      assert_equal(3, filter.redis_pool)
    end
  end

  sub_test_case 'record configuration' do
    test 'empty record parsing' do
      driver = create_driver('key abc')
      filter = driver.instance

      assert_equal({}, filter.record_enrichment)
    end

    test 'record configuration parsing' do
      conf = %(
        key key_test
        <record>
          key_1  expand of this
          key_2  expand of that
        </record>
      )

      driver = create_driver(conf)
      filter = driver.instance

      assert_equal({ 'key_1' => 'expand of this',
                     'key_2' => 'expand of that' },
                   filter.record_enrichment)
    end
  end

  # sub_test_case '' do
  # end

  private

  CONFIG = %(
  )

  def create_driver(conf = CONFIG)
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::RedisEnrichmentFilter).configure(conf)
  end
end

# test unit for Cache new factory
class CacheFactory < Test::Unit::TestCase
  setup do
    Fluent::Test.setup

    @fake_redis = FakeRedis.new({ 'data1' => 1,
                                  'data2' => 2 })
  end

  sub_test_case 'init' do
    test 'it returns the NoCache when type is no' do
      cache = Fluent::Plugin::RedisEnrichmentFilter::Cache.new(redis: @fake_redis, type: :no)
      assert cache.instance_of? Fluent::Plugin::RedisEnrichmentFilter::Cache::NoCache
    end

    test 'it returns the FullCache when type is full' do
      cache = Fluent::Plugin::RedisEnrichmentFilter::Cache.new(redis: @fake_redis, type: :full)
      assert cache.instance_of? Fluent::Plugin::RedisEnrichmentFilter::Cache::FullCache
      cache.clean
    end

    test 'it returns the LazyCache when type is lazy' do
      cache = Fluent::Plugin::RedisEnrichmentFilter::Cache.new(redis: @fake_redis, type: :lazy)
      assert cache.instance_of? Fluent::Plugin::RedisEnrichmentFilter::Cache::LazyCache
    end
  end
end

# test unit for Cache::NoCache
class CacheNoCacheTest < Test::Unit::TestCase
  setup do
    Fluent::Test.setup

    @fake_redis = FakeRedis.new({ 'data1' => 1,
                                  'data2' => 2 })
  end

  sub_test_case 'init' do
    test 'can be instantiated without any args' do
      assert_nothing_raised do
        Fluent::Plugin::RedisEnrichmentFilter::Cache::NoCache.new(redis: nil)
      end
    end
  end

  sub_test_case 'get' do
    test 'forward all call to redis' do
      cache = Fluent::Plugin::RedisEnrichmentFilter::Cache::NoCache.new(redis: @fake_redis)

      assert_equal 1, cache.get('data1')
      assert_equal 2, cache.get('data2')

      assert_equal 2, @fake_redis.call_count
    end

    test 'forward all call to redis without caching' do
      cache = Fluent::Plugin::RedisEnrichmentFilter::Cache::NoCache.new(redis: @fake_redis)

      assert_equal 1, cache.get('data1')
      assert_equal 1, cache.get('data1')

      assert_equal 2, @fake_redis.call_count
    end
  end
end

# test unit for Cache::LazyCache
class CacheLazyCacheTest < Test::Unit::TestCase
  setup do
    Fluent::Test.setup

    @fake_redis = FakeRedis.new({ 'data1' => 1,
                                  'data2' => 2 })
  end

  sub_test_case 'init' do
    test 'can be instantiated' do
      assert_nothing_raised do
        Fluent::Plugin::RedisEnrichmentFilter::Cache::LazyCache.new(redis: @fake_redis)
      end
    end

    test 'init does not preload cache' do
      Fluent::Plugin::RedisEnrichmentFilter::Cache::LazyCache.new(redis: @fake_redis)

      assert_equal 0, @fake_redis.call_count
    end
  end

  sub_test_case 'get' do
    test 'call are forwarded to redis' do
      cache = Fluent::Plugin::RedisEnrichmentFilter::Cache::LazyCache.new(redis: @fake_redis)

      assert_equal 1, cache.get('data1')
      assert_equal 2, cache.get('data2')

      assert_equal 2, @fake_redis.call_count
    end

    test 'call are cached' do
      cache = Fluent::Plugin::RedisEnrichmentFilter::Cache::LazyCache.new(redis: @fake_redis)

      assert_equal 1, cache.get('data1')
      assert_equal 1, cache.get('data1')

      assert_equal 1, @fake_redis.call_count
    end
  end
end

# test unit for Cache::FullCache
class CacheFullCacheTest < Test::Unit::TestCase
  setup do
    Fluent::Test.setup

    @fake_redis = FakeRedis.new({ 'data1' => 1,
                                  'data2' => 2 })
  end

  sub_test_case 'init' do
    test 'can be instantiated' do
      assert_nothing_raised do
        cache = Fluent::Plugin::RedisEnrichmentFilter::Cache::FullCache.new(redis: @fake_redis)
        cache.clean
      end
    end

    test 'init preload cache' do
      cache = Fluent::Plugin::RedisEnrichmentFilter::Cache::FullCache.new(redis: @fake_redis)
      cache.clean

      assert_equal 1, @fake_redis.call_count
    end
  end

  sub_test_case 'get' do
    test 'call are already cached' do
      cache = Fluent::Plugin::RedisEnrichmentFilter::Cache::FullCache.new(redis: @fake_redis)

      assert_equal 1, @fake_redis.call_count

      assert_equal 1, cache.get('data1')
      assert_equal 2, cache.get('data2')

      assert_equal 1, @fake_redis.call_count

      cache.clean
    end

    test 'call are already for the same key' do
      cache = Fluent::Plugin::RedisEnrichmentFilter::Cache::FullCache.new(redis: @fake_redis)

      assert_equal 1, @fake_redis.call_count

      assert_equal 1, cache.get('data1')
      assert_equal 1, cache.get('data1')

      assert_equal 1, @fake_redis.call_count

      cache.clean
    end
  end
end
