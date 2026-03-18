require "json"

module C2PA
  class Manifest
    # @param title [String] human-readable title for this asset
    def initialize(title:)
      @title = title
      @actions = []
      @assertions = []
      @ingredients = []
    end

    # Add a C2PA action to this manifest.
    #
    # @param action [String] one of the C2PA::Actions constants
    # @param when_time           [String, nil] ISO 8601 timestamp of when the action occurred
    # @param software_agent      [String, nil] name/version of the software that performed the action;
    #                                          defaults to "ruby-c2pa/<version>"
    # @param digital_source_type [String, nil] URI from the C2PA digitalSourceType vocabulary
    # @param changed             [Array<String>, nil] list of regions or ingredients that changed
    # @param parameters          [Hash, nil] action-specific additional parameters
    # @return [self]
    def add_action(action,
                   when_time: nil,
                   software_agent: nil,
                   digital_source_type: nil,
                   changed: nil,
                   parameters: nil)
      entry = { "action" => action }
      entry["when"]              = when_time                              if when_time
      entry["softwareAgent"]     = software_agent || "ruby-c2pa/#{VERSION}"
      entry["digitalSourceType"] = digital_source_type                   if digital_source_type
      entry["changed"]           = changed                               if changed
      entry["parameters"]        = parameters                            if parameters
      @actions << entry
      self
    end

    # Add an arbitrary assertion to this manifest.
    #
    # @param label [String] the assertion label, e.g. "stds.schema-org.CreativeWork"
    # @param data  [Hash]   the assertion data
    # @return [self]
    def add_assertion(label:, data:)
      @assertions << { "label" => label, "data" => data }
      self
    end

    # Add an ingredient (source asset) to this manifest.
    #
    # @param title       [String] human-readable title of the ingredient
    # @param format      [String] MIME type of the ingredient, e.g. "image/jpeg"
    # @param instance_id [String] unique identifier for the ingredient instance
    # @param relationship [String] relationship to this asset; defaults to "parentOf"
    # @return [self]
    def add_ingredient(title:, format:, instance_id:, relationship: "parentOf")
      @ingredients << {
        "title"        => title,
        "format"       => format,
        "instance_id"  => instance_id,
        "relationship" => relationship
      }
      self
    end

    # Serialize to the JSON structure expected by c2pa-rs.
    #
    # @return [String]
    # @raise [C2PA::InvalidManifestError] if no actions have been added
    def to_json
      raise InvalidManifestError, "at least one action is required" if @actions.empty?

      manifest = {
        "title" => @title,
        "assertions" => [
          { "label" => "c2pa.actions.v2", "data" => { "actions" => @actions } },
          *@assertions
        ]
      }
      manifest["ingredients"] = @ingredients unless @ingredients.empty?

      JSON.generate(manifest)
    end
  end
end
