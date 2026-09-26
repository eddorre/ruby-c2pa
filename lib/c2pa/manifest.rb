require "json"

module C2PA
  class Manifest
    # Intents this gem can express.
    #
    # :edit   — this asset derives from a parent. c2pa-rs generates the parent
    #           ingredient from the source file and adds a c2pa.opened action
    #           wired to it by hashed URI.
    # :update — a restricted edit for non-editorial changes, such as fixing
    #           metadata. The parent is the source file itself; an explicit
    #           ingredient, if given, must be that same file.
    #
    # Omitting the intent produces a manifest for a newly created asset.
    INTENTS = %i[edit update].freeze

    # c2pa-rs records itself in a namespaced field alongside the generator
    # name, so the gem does the same when an application supplies its own.
    GEM_FIELD = "org.rubygems.ruby_c2pa".freeze

    # @return [Symbol, nil] the builder intent, if any
    attr_reader :intent

    # @param title  [String] human-readable title for this asset
    # @param intent [Symbol, nil] :edit; omit for a new creation
    # @param generator_name    [String, nil] the application doing the signing.
    #   Defaults to this gem. Supplying it credits your application as the
    #   claim generator, with the gem recorded alongside.
    # @param generator_version [String, nil] version of that application
    # @raise [C2PA::InvalidManifestError] if the intent is not recognised
    def initialize(title:, intent: nil, generator_name: nil, generator_version: nil)
      unless intent.nil? || INTENTS.include?(intent)
        raise InvalidManifestError,
              "unknown intent #{intent.inspect}. Valid options: #{INTENTS.map(&:inspect).join(', ')}"
      end

      @title = title
      @intent = intent
      @generator_name = generator_name
      @generator_version = generator_version
      @actions = []
      @assertions = []
      @ingredients = []
      @ingredient_files = []
    end

    # Ingredients supplied as files, for the signing layer to hand to c2pa-rs.
    # Each is a Hash with the ingredient's JSON description, its format, and
    # the path to read.
    #
    # @return [Array<Hash>]
    attr_reader :ingredient_files

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

      # Required as of c2pa-rs 0.90. Earlier versions accepted its absence, so
      # manifests signed by releases before 0.3.0 are rejected by current
      # verifiers. No default is supplied: c2pa-rs accepts any string here, so
      # a guess would validate while asserting something untrue about where the
      # asset came from. Use DigitalSourceTypes::UNSPECIFIED to decline.
      if action == Actions::CREATED && to_s_or_nil(digital_source_type).nil?
        raise InvalidManifestError,
              "#{Actions::CREATED} requires a digital_source_type. Choose the value that " \
              "describes how the asset was produced — for example " \
              "C2PA::DigitalSourceTypes::DIGITAL_CAPTURE for a camera original, or " \
              "TRAINED_ALGORITHMIC_MEDIA for generative AI. If the origin is genuinely " \
              "unknown, use C2PA::DigitalSourceTypes::UNSPECIFIED rather than guessing."
      end

      # Also new in c2pa-rs 0.90.
      if action == Actions::TRANSLATED
        missing = %w[sourceLanguage targetLanguage].reject { |key| param_present?(parameters, key) }
        unless missing.empty?
          raise InvalidManifestError,
                "#{Actions::TRANSLATED} requires #{missing.join(' and ')} in parameters, " \
                "as RFC 5646 language codes"
        end
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
    # With `file:`, c2pa-rs reads the ingredient itself. If that file carries
    # content credentials, its manifest is embedded and the ingredient points
    # at it, so provenance chains from the original through to this asset. A
    # verifier can then follow and check the whole history.
    #
    # For a file with no credentials there is nothing to carry forward, and
    # the result is the same as the description alone. (Thumbnails would be
    # the other contribution, but they need c2pa-rs's `add_thumbnails`
    # feature, which this gem does not enable.)
    #
    # Without `file:`, only the description is recorded. Nothing binds it to
    # any actual bytes. This form is kept for compatibility.
    #
    # @param title        [String] human-readable title of the ingredient
    # @param format       [String] MIME type of the ingredient, e.g. "image/jpeg"
    # @param instance_id  [String] unique identifier for the ingredient instance
    # @param relationship [String] relationship to this asset; defaults to "parentOf"
    # @param file         [String, nil] path to the ingredient file
    # @param digital_source_type [String, nil] URI from the C2PA digitalSourceType
    #   vocabulary, for an ingredient with no content credentials of its own,
    #   such as a generated image composited into this asset
    # @return [self]
    # @raise [C2PA::InvalidManifestError] if `file` is given but cannot be read,
    #   or if `digital_source_type` is given for a file that carries content
    #   credentials
    def add_ingredient(title:, format:, instance_id:, relationship: "parentOf", file: nil,
                       digital_source_type: nil)
      description = {
        "title"        => title,
        "format"       => format,
        "instance_id"  => instance_id,
        "relationship" => relationship
      }
      digital_source_type = to_s_or_nil(digital_source_type)
      description["digital_source_type"] = digital_source_type if digital_source_type

      if file.nil?
        @ingredients << description
        return self
      end

      unless File.file?(file) && File.readable?(file)
        raise InvalidManifestError, "ingredient file not readable: #{file.inspect}"
      end

      # The specification forbids a source type alongside an embedded manifest:
      # an ingredient with credentials already records its own origin. c2pa-rs
      # refuses the combination only at signing, as "unable to encode assertion
      # data", so it is caught here where the cause is clear.
      if digital_source_type && content_credentials?(file)
        raise InvalidManifestError,
              "digital_source_type cannot be set for #{file.inspect}: it carries content " \
              "credentials, which already record where it came from"
      end

      @ingredient_files << {
        "json"   => JSON.generate(description),
        "format" => format,
        "path"   => File.expand_path(file)
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
        "claim_generator_info" => [claim_generator_info],
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

    private

    # A file with no manifest, or one c2pa-rs cannot read, counts as having no
    # credentials; if it does carry some, signing still fails upstream.
    def content_credentials?(file)
      !C2PA.read(file: file)["active_manifest"].nil?
    rescue ReadError
      false
    end

    # Parameters may be keyed with strings or symbols depending on the caller.
    def param_present?(parameters, key)
      return false unless parameters.is_a?(Hash)

      !to_s_or_nil(parameters[key] || parameters[key.to_sym]).nil?
    end

    def to_s_or_nil(value)
      return nil if value.nil?

      string = value.to_s
      string.empty? ? nil : string
    end

    # Who signed this. Without it c2pa-rs names itself, so every asset this gem
    # produced credited "c2pa-rs" and nothing identified the gem or the
    # application using it.
    #
    # c2pa-rs 0.78 permits exactly one entry — supplying two fails with "only 1
    # claim_generator_info allowed" — so an application name replaces the gem
    # rather than preceding it, and the gem moves into a namespaced field. That
    # mirrors how c2pa-rs records itself as org.contentauth.c2pa_rs.
    def claim_generator_info
      return { "name" => "ruby-c2pa", "version" => VERSION } if @generator_name.nil?

      info = { "name" => @generator_name }
      info["version"] = @generator_version if @generator_version
      info[GEM_FIELD] = VERSION
      info
    end
  end
end
