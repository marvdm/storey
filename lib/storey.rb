require "storey/version"
require "rails/all"
require "active_support/core_ext/module" # so we can use mattr_accessor
require 'storey/railtie' if defined?(Rails)
require 'storey/exceptions'
require 'storey/migrator'

module Storey
  extend self

  autoload :Duplicator, 'storey/duplicator'

  mattr_accessor :suffix, :default_search_path, :persistent_schemas
  mattr_reader :excluded_models

  def init
    @@default_search_path = schema
    self.excluded_models ||= []
    self.persistent_schemas ||= []
    process_excluded_models
  end

  def excluded_models=(array)
    @@excluded_models = array
    process_excluded_models
  end

  def schema(options={})
    options[:suffix] ||= false

    name = ActiveRecord::Base.connection.schema_search_path

    if options[:suffix]
      name
    else
      unsuffixify name
    end
  end

  def create(name, options={}, &block)
    fail ArgumentError, "Must pass in a valid schema name" if name.blank?

    options[:load_database_schema] = true unless options.has_key?(:load_database_schema)

    name = suffixify(name)
    ActiveRecord::Base.connection.execute "CREATE SCHEMA #{name}"
    switch name do
      load_database_schema if options[:load_database_schema] == true
      block.call if block_given?
    end
  rescue ActiveRecord::StatementInvalid => e
    if e.to_s =~ /schema ".+" already exists/
      fail Storey::SchemaExists, %{The schema "#{name}" already exists.}
    else
      raise e
    end
  end

  def schemas(options={})
    options[:suffix] ||= false
    options[:public] = true unless options.has_key?(:public)

    sql = "SELECT nspname FROM pg_namespace"
    sql << " WHERE nspname !~ '^pg_.*'"
    sql << " AND nspname != 'information_schema'"
    sql << " AND nspname != 'public'" unless options[:public]

    names = ActiveRecord::Base.connection.query(sql).flatten

    if options[:suffix]
      names
    else
      names = names.map {|name| unsuffixify(name)}
    end
  end

  def drop(name)
    name = suffixify name
    ActiveRecord::Base.connection.execute("DROP SCHEMA #{name} CASCADE")
  rescue ActiveRecord::StatementInvalid => e
    raise Storey::SchemaNotFound, %{The schema "#{name}" cannot be found.}
  end

  def switch(name=nil, &block)
    if block_given?
      original_schema = schema
      switch name
      result = block.call
      switch original_schema
      result
    else
      reset and return if name.blank?
      path = self.schema_search_path_for(name)
      ActiveRecord::Base.connection.schema_search_path = path
    end
  rescue ActiveRecord::StatementInvalid => e
    if e.to_s =~ /invalid value for parameter "search_path"/
      fail Storey::SchemaNotFound, %{The schema "#{path}" cannot be found.}
    else
      raise e
    end
  end

  def schema_search_path_for(schema_name)
    path = [suffixify(schema_name)]
    self.persistent_schemas.each do |schema|
      path << suffixify(schema)
    end
    path.uniq.join(',')
  end

  def reload_config!
    self.excluded_models = []
    self.persistent_schemas = []
    self.suffix = nil
  end

  def database_config
    Rails.configuration.database_configuration[Rails.env].with_indifferent_access
  end

  def duplicate!(from_schema, to_schema)
    duplicator = Duplicator.new from_schema, to_schema
    duplicator.perform!
  end

  def suffixify(name)
    if Storey.suffix && !name.include?(Storey.suffix) && name != self.default_search_path
      "#{name}#{Storey.suffix}"
    else
      name
    end
  end

  def unsuffixify(name)
    search_path = name
    if Storey.suffix
      paths = []
      name.split(',').each do |schema|
        result = if schema =~ /(\w+)#{Storey.suffix}/
                   $1
                 else
                   schema
                 end
        paths << result
      end
      search_path = paths.join(',')
    end
    search_path
  end

  protected

  def schema_migrations
    ActiveRecord::Migrator.get_all_versions
  end

  def reset
    path = self.schema_search_path_for(self.default_search_path)
    ActiveRecord::Base.connection.schema_search_path = path
  end

  # Loads the Rails schema.rb into the current schema
  def load_database_schema
    ActiveRecord::Schema.verbose = false # do not log schema load output.
    load_or_abort("#{Rails.root}/db/schema.rb")
  end

  def load_or_abort(file)
    if File.exists?(file)
      load(file)
    else
      abort %{#{file} doesn't exist yet}
    end
  end

  def process_excluded_models
    self.excluded_models.each do |model_name|
      model_name.constantize.tap do |klass|
        table_name = klass.table_name.split('.', 2).last
        klass.table_name = "public.#{table_name}"
      end
    end
  end
end
