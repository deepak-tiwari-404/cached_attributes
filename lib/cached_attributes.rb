require "cached_attributes/version"

module CachedAttributes
  def self.included(base)
    base.class_attribute :cached_column_names, :cached_column_store
    base.extend ClassMethods
  end

  module ClassMethods
    CACHE_COLUMN_STORE_LIMIT = 10

    def cached_attributes(*attributes)
      attributes = attributes.map(&:to_s)
      columns = self.columns.map{|x| x.name}
      matched_columns = attributes & columns
      if matched_columns.size == attributes.size
        self.cached_column_names = attributes
      else
        not_found_columns = attributes - matched_columns
        raise "No match for #{'Column Name'.pluralize(not_found_columns.size)}: #{not_found_columns.join(',')}"
      end
      self.cached_column_store = {}
      self.cached_column_names.each do |key|
        self.cached_column_store[key] = []
      end
      self.class_eval do
        define_method("after_commit_reset_cache_store") do
          self.cached_column_store.keys.each{|key| self.cached_column_store[key] = []}
        end
      end
      after_commit :after_commit_reset_cache_store, on: [:update, :destroy]
    end

    def respond_to?(name, include_private = false)
      match = FindByMethod.match(self, name)
      match && match.valid? || super
    end

    private

    def method_missing(name, *arguments, &block)
      match = FindByMethod.match(self, name)

      if match && match.valid?
        match.define
        send(name, *arguments, &block)
      else
        super
      end
    end

    class FindByMethod
      class << self

        def match(model, name)
          new(model, name) if name =~ pattern
        end

        def pattern
          @pattern ||= /\A#{prefix}_([_a-zA-Z]\w*)#{suffix}\Z/
        end

        def prefix
          "find_by"
        end

        def suffix
          ''
        end
      end

      attr_reader :model, :name, :attribute_name

      def initialize(model, name)
        @model           = model
        @name            = name.to_s
        @attribute_name = @name.match(self.class.pattern)[1]
        @attribute_name = @model.attribute_aliases[@attribute_name] || @attribute_name
      end

      def valid?
        @model.cached_column_names.include?(@attribute_name)
      end

      def define
        model.class_eval <<-CODE, __FILE__, __LINE__ + 1
          def self.#{name}(#{signature})
            cache_store = self.cached_column_store["#{attribute_name}"]
            result = cache_store.find{|record| record.send("#{attribute_name}") == #{signature}}
            unless result
              result = #{super_method}
              self.cached_column_store["#{attribute_name}"][cache_store.size % CACHE_COLUMN_STORE_LIMIT] = result if result
            end
            result
          end
        CODE
      end

      private

      def finder
        "find_by"
      end

      def super_method
        "#{finder}({:#{attribute_name} => #{signature}})"
      end

      def signature
        "_#{attribute_name}"
      end
    end
  end
end
