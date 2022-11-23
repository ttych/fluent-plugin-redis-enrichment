# frozen_string_literal: true

require 'helper'
require 'fluent/plugin/filter_redis_enrichment'

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
