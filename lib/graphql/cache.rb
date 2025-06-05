# frozen_string_literal: true

require 'graphql/cache/version'
require 'graphql/cache/field'
require 'graphql/cache/extension'
require 'graphql/cache/key'
require 'graphql/cache/marshal'
require 'graphql/cache/fetcher'

module GraphQL
  module Cache
    class << self
      # An object that must conform to the same API as ActiveSupport::Cache::Store
      # @return [Object] Defaults to `Rails.cache` in a Rails environment
      attr_accessor :cache

      # Global default cache key expiration time in seconds.
      # @return [Integer] Default: 5400 (90 minutes)
      attr_accessor :expiry

      # Logger instance to use when logging cache hits/misses.
      # @return [Logger]
      attr_accessor :logger

      # Global namespace for keys
      # @return [String] Default: "GraphQL::Cache"
      attr_accessor :namespace

      # Provides for initializer syntax
      #
      # ```
      # GraphQL::Cache.configure do |c|
      #   c.namespace = 'MyNamespace'
      # end
      # ```
      def configure
        yield self
      end
    end

    # Default configuration
    @expiry    = 5400
    @namespace = 'graphql'

    # Called by plugin framework in graphql-ruby to
    # bootstrap necessary instrumentation and tracing
    # tie-ins
    def self.use(schema_def, options: {})
      # For GraphQL 2.x, we don't use field instrumentation
      # Instead, users should use GraphQL::Cache::Field as their field class
      # or manually add the GraphQL::Cache::Extension to fields
      
      # For backward compatibility with GraphQL 1.x, we still support field instrumentation
      if schema_def.respond_to?(:instrument)
        fetcher = ::GraphQL::Cache::Fetcher.new
        schema_def.instrument(:field, fetcher)
      end
    end
  end
end

require 'graphql/cache/rails' if defined?(::Rails::Engine)
