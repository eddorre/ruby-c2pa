require "json"

module C2PA
  class Manifest
    # Intents this gem can express.
    #
    # :edit — this asset derives from a parent. c2pa-rs generates the parent
    #         ingredient from the source file and adds a c2pa.opened action
    #         wired to it by hashed URI.
    #
    # Omitting the intent produces a manifest for a newly created asset.
    #
    # c2pa-rs also has an :update intent, a restricted edit for non-editorial
    # changes. It is not offered here because it requires an ingredient with
    # real content, and add_ingredient records metadata only — signing with it
    # fails with "ingredient file not found". Tracked separately.
    INTENTS = %i[edit].freeze

    # @return [Symbol, nil] the builder intent, if any
    attr_reader :intent

    # @param title  [String] human-readable title for this asset
    # @param intent [Symbol, nil] :edit or :update; omit for a new creation
    # @raise [C2PA::InvalidManifestError] if the intent is not recognised
    def initialize(title:, intent: nil)
      unless intent.nil? || INTENTS.include?(intent)
        raise InvalidManifestError,
              "unknown intent #{intent.inspect}. Valid options: #{INTENTS.map(&:inspect).join(', ')}"
      end

      @title = title
      @intent = intent
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
      if action == Actions::OPENED
        raise InvalidManifestError,
              "#{Actions::OPENED} cannot be added directly. The specification requires it to " \
              "reference a parentOf ingredient by hashed URI, and that hash is computed over " \
              "the ingredient as c2pa-rs serialises it, so Ruby cannot construct one. Pass " \
              "intent: :edit to C2PA::Manifest.new instead and the action will be added for you."
      end

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
    # @raise [C2PA::InvalidManifestError] if no actions have been added, or if
    #   any value cannot be represented as JSON
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

      begin
        JSON.generate(manifest)
      rescue JSON::GeneratorError => e
        # Typically a string that is not valid UTF-8 — a filename or caption
        # read in another encoding and passed through untouched. Without this
        # the caller gets a JSON::GeneratorError, which is not a C2PA::Error
        # and so escapes `rescue C2PA::Error`.
        raise InvalidManifestError,
              "manifest contains text that cannot be encoded as JSON: #{e.message}"
      end
    end
  end
end
