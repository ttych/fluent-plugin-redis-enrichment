# frozen_string_literal: true

require 'helper'
require 'fluent/plugin/filter_redis_enrichment'

class RedisEnrichmentFilterTest < Test::Unit::TestCase
  setup do
    Fluent::Test.setup
  end

  test 'failure' do
    flunk
  end

  private

  def create_driver(conf)
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::RedisEnrichmentFilter).configure(conf)
  end
end
