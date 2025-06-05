module GraphQL
  module Cache
    # GraphQL objects can't be serialized to cache so we have
    # to maintain an abstraction between the raw cache value
    # and the GraphQL expected object. This class exposes methods
    # for deconstructing an object to be stored in cache
    #
    class Deconstructor
      # The raw value to perform actions on. Could be a raw cached value, or
      # a raw GraphQL Field.
      #
      # @return [Object]
      attr_accessor :raw

      # A flag indicating the type of object construction to
      # use when building a new GraphQL object. Can be one of
      # 'array', 'collectionproxy', 'relation', 'lazy'. These values
      # have been chosen because it is easy to use the class
      # names of the possible object types for this purpose.
      #
      # @return [String] 'array' or 'collectionproxy' or 'relation' or 'lazy'
      attr_accessor :method

      # Initializer helper that generates a valid `method` string based
      # on `raw.class.name`.
      #
      # @return [Object] A newly initialized GraphQL::Cache::Deconstructor instance
      def self.[](raw)
        build_method = namify(raw.class.name)
        new(raw, build_method)
      end

      # Ruby-only means of "demodularizing" a string
      def self.namify(str)
        str.split('::').last.downcase
      end

      def initialize(raw, method)
        self.raw    = raw
        self.method = method
      end

      # Deconstructs a GraphQL field into a cachable value
      #
      # @return [Object] A value suitable for writing to cache or a lazily
      # resolved value
      def perform
        if method == 'lazy'
          raw.then { |resolved_raw| self.class[resolved_raw].perform }
        elsif %(array collectionproxy).include? method
          deconstruct_array(raw)
        elsif connection_object?(raw)
          extract_nodes_from_connection(raw)
        else
          deconstruct_object(raw)
        end
      end

      private

      # Check if the object is a connection (GraphQL 1.x or 2.x)
      def connection_object?(obj)
        # Check for GraphQL 2.x connection classes
        return true if defined?(GraphQL::Pagination::Connection) && obj.is_a?(GraphQL::Pagination::Connection)
        
        # Check for GraphQL 1.x connection classes (backward compatibility)
        if defined?(GraphQL::Relay::BaseConnection)
          return true if obj.class.ancestors.include?(GraphQL::Relay::BaseConnection)
        end
        
        false
      end

      # Extract nodes from connection object (GraphQL 1.x or 2.x)
      def extract_nodes_from_connection(connection)
        if connection.respond_to?(:nodes)
          connection.nodes
        elsif connection.respond_to?(:edge_nodes)
          connection.edge_nodes
        else
          # Fallback: try to extract items from the connection
          connection
        end
      end

      # @private
      def deconstruct_array(raw)
        return [] if raw.empty?

        if raw.first.class.ancestors.include? GraphQL::Schema::Object
          raw.map(&:object)
        elsif array_contains_promise?(raw)
          Promise.all(raw).then { |resolved| deconstruct_array(resolved) }
        else
          raw
        end
      end

      # @private
      def array_contains_promise?(raw)
        raw.any? { |element| element.class.name == 'Promise' }
      end

      # @private
      def deconstruct_object(raw)
        if raw.respond_to?(:object)
          raw.object
        else
          raw
        end
      end
    end
  end
end

