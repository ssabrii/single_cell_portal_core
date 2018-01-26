##
#
# HCAMetadatum: Module that all HCA-style metadata objects inherit from.  Contains general getters/setters
# for loading and parsing source metadata schema objects
#
##

module HCAUtilities
  # root directory for storing metadata schema copies
  #
  # * *params*
  #   - +version+ (String) => schema version number of this metadata object
  #
  # * *return*
  #   - +Pathname+ => path to root directory containing JSON files of same version number
  def get_definition_root(version)
    Rails.root.join('data', 'HCA_metadata', version)
  end

  # remote endpoint containing metadata schema
  #
  # * *params*
  #   - +version+ (String) => schema version number of this metadata object
  #   - +entity+ (String) => name of metadata entity (e.g. analysis, project, sample, etc.)
  #
  # * *return*
  #   - +String+ => url to remote schema definition JSON in github
  def get_definition_url(version, entity)
    "https://raw.githubusercontent.com/HumanCellAtlas/metadata-schema/#{version}/json_schema/#{entity}.json"
  end

  # local filesytem location of copy of JSON schema

  # * *params*
  #   - +filename+ (String) => filename of metadata schema JSON
  #
  # * *return*
  #   - +Pathname+ => path to metadata schema JSON file
  def get_definition_filepath(filename, version)
    Rails.root.join(self.get_definition_root(version), filename)
  end

  # return a parsed JSON object detailing the metadata schema for this object
  # * *params*
  #   - +filename+ (String) => filename of metadata schema JSON
  #   - +version+ (String) => schema version number of this metadata object
  #
  # * *return*
  #   - +Hash+ => Hash of metadata schema values, or error message
  def parse_definition_schema(filename, version)
    begin
      entity = filename.split('.').first
      # check for local copy first
      if File.exists?(self.get_definition_filepath(filename, version))
        existing_schema = File.read(self.get_definition_filepath(filename, version))
        JSON.parse(existing_schema)
      else
        Rails.logger.info "#{Time.now}: saving new local copy of #{self.get_definition_filepath(filename, version)}"
        metadata_schema = RestClient.get self.get_definition_url(version, entity)
        # write a local copy
        unless Dir.exist?(self.get_definition_root(version))
          FileUtils.mkdir_p(self.get_definition_root(version))
        end
        new_schema = File.new(self.get_definition_filepath(filename, version), 'w+')
        new_schema.write metadata_schema.body
        new_schema.close
        JSON.parse(metadata_schema.body)
      end
    rescue RestClient::ExceptionWithResponse => e
      Rails.logger.error "#{Time.now}: Error retrieving remote HCA #{filename} metadata schema: #{e.message}"
      {error: "Error retrieving definition schema: #{e.message}"}
    rescue JSON::ParserError => e
      Rails.logger.error "#{Time.now}: Error parsing HCA #{filename} metadata schema: #{e.message}"
      {error: "Error parsing definition schema: #{e.message}"}
    end
  end

  # retrieve property or nested field definition information
  # can retrieve info such as require fields, field definitions, property list, etc.
  #
  # * *params*
  #   - +filename+ (String) => filename of metadata schema JSON
  #   - +version+ (String) => schema version number of this metadata object
  #   - +key+ (String) => root-level key to retrieve from metadata object (e.g. properties, required, etc.)
  #   - +field+ (String) => (optional) sub-level key to retrieve from metadata object
  #
  # * *return*
  #   - +Hash+ => Hash of object definitions
  def parse_definitions(filename, version, key, field=nil)
    begin
      defs = self.parse_definition_schema(filename, version)[key]
      if field.present?
        defs[field]
      else
        defs
      end
    rescue NoMethodError => e
      field_key = field.present? ? "#{key}/#{field}" : key
      Rails.logger.error "#{Time.now}: Error accessing remote HCA Analysis metadata field definitions for #{field_key}: #{e.message}"
      nil
    end
  end

  # set a value based on the schema definition for a particular field
  #
  # * *params*
  #   - +definitions+ (Hash) => Hash of field defintions (from *definitions* or *child_definitions*)
  #   - +value+ (Multiple) => value to set
  #
  # * *return*
  #   - +Multiple+ => Can return String, Integer, Array
  #
  # * *raises*
  #   - +TypeError+ => if value to be set does not match the *definitions['pattern']* attribute (if present)
  def set_value_by_type(definitions, value)
    value_type = definitions['type']
    value_pattern = definitions['pattern']
    case value_type
      when 'string'
        if value_pattern.present?
          if (value =~ Regexp.new(value_pattern).freeze).present?
            value
          else
            raise TypeError.new("#{value} does not conform to the expected format of #{value_pattern}")
          end
        else
          value
        end
      when 'integer'
        value.to_i
      when 'array'
        if value.is_a?(Array)
          value
        elsif value.is_a?(String)
          # try to split on commas to convert into array
          value.split(',')
        end
      else
        value
    end
  end
end