#!/usr/bin/env ruby

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))

require 'graphql'
require 'graphql/cache'
require 'logger'
require 'ostruct'

puts "GraphQL-Ruby version: #{GraphQL::VERSION}"

# Set up logger
GraphQL::Cache.logger = Logger.new(STDOUT)
GraphQL::Cache.logger.level = Logger::DEBUG

# Test schema with cache
begin
  class BaseObject < GraphQL::Schema::Object
    field_class GraphQL::Cache::Field
  end

  class TestType < BaseObject
    field :cached_field, String, cache: true
    field :normal_field, String
    
    def cached_field
      puts "  -> Executing cached_field method (should only see this on cache miss)"
      "cached value"
    end
    
    def normal_field
      puts "  -> Executing normal_field method (should see this every time)"
      "normal value"
    end
  end

  # Create a persistent test object with a stable ID
  class TestObject < OpenStruct
    def id
      1 # Fixed ID for consistent cache keys
    end
  end

  class Query < BaseObject
    field :test, TestType, null: false
    
    def test
      @test_object ||= TestObject.new # Reuse the same object instance
    end
  end

  class TestSchema < GraphQL::Schema
    query Query
    use GraphQL::Cache
  end

  puts "✓ Schema with GraphQL::Cache created successfully"
rescue => e
  puts "✗ Schema creation failed: #{e.message}"
  puts e.backtrace.first(3)
end

# Test query execution
begin
  # Set up a simple cache
  cache_store = {}
  cache_object = Object.new
  cache_object.define_singleton_method(:read) { |key| cache_store[key] }
  cache_object.define_singleton_method(:write) { |key, value, **opts| cache_store[key] = value }
  
  GraphQL::Cache.cache = cache_object
  
  puts "\n=== First Query (should be cache miss) ==="
  result1 = TestSchema.execute('{ test { cachedField normalField } }')
  puts "Result: #{result1.to_h}"
  
  puts "\n=== Second Query (should be cache hit) ==="
  result2 = TestSchema.execute('{ test { cachedField normalField } }')
  puts "Result: #{result2.to_h}"
  
  puts "\n✓ Query executed successfully"
rescue => e
  puts "✗ Query execution failed: #{e.message}"
  puts e.backtrace.first(3)
end

puts "\nTest completed!" 