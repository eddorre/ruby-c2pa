module C2PA
  # URIs from the IPTC Digital Source Type NewsCodes vocabulary.
  #
  # The C2PA specification requires every c2pa.created action to declare one of
  # these, so consumers can tell how the asset came into being. Pick the one that
  # honestly describes the asset — this is a provenance claim, and c2pa-rs will
  # not second-guess the value you supply.
  #
  # @see https://cv.iptc.org/newscodes/digitalsourcetype/
  module DigitalSourceTypes
    BASE = "http://cv.iptc.org/newscodes/digitalsourcetype"

    # Declining to claim a source type, rather than guessing at one.
    #
    # c2pa-rs requires c2pa.created to carry a digitalSourceType but accepts
    # any string, so a wrong value validates silently. When the origin is not
    # known — a generic signing service, say — this says so, instead of
    # asserting something untrue. It is the value c2pa-rs uses throughout its
    # own fixtures.
    UNSPECIFIED = "http://c2pa.org/digitalsourcetype/empty"

    # Captured from real life
    DIGITAL_CAPTURE       = "#{BASE}/digitalCapture"
    COMPUTATIONAL_CAPTURE = "#{BASE}/computationalCapture"
    SCREEN_CAPTURE        = "#{BASE}/screenCapture"
    VIRTUAL_RECORDING     = "#{BASE}/virtualRecording"

    # Digitised from a physical medium
    NEGATIVE_FILM = "#{BASE}/negativeFilm"
    POSITIVE_FILM = "#{BASE}/positiveFilm"
    PRINT         = "#{BASE}/print"

    # Human- or software-authored
    HUMAN_EDITS              = "#{BASE}/humanEdits"
    DIGITAL_CREATION         = "#{BASE}/digitalCreation"
    ALGORITHMICALLY_ENHANCED = "#{BASE}/algorithmicallyEnhanced"
    DATA_DRIVEN_MEDIA        = "#{BASE}/dataDrivenMedia"
    ALGORITHMIC_MEDIA        = "#{BASE}/algorithmicMedia"

    # Generative AI
    TRAINED_ALGORITHMIC_MEDIA                = "#{BASE}/trainedAlgorithmicMedia"
    COMPOSITE_WITH_TRAINED_ALGORITHMIC_MEDIA = "#{BASE}/compositeWithTrainedAlgorithmicMedia"
    COMPOSITE_SYNTHETIC                      = "#{BASE}/compositeSynthetic"

    # Composites
    COMPOSITE         = "#{BASE}/composite"
    COMPOSITE_CAPTURE = "#{BASE}/compositeCapture"

    # Every type defined above. Supplying a URI outside this list is allowed —
    # the vocabulary is extensible — but the values here cover the standard set.
    ALL = [
      UNSPECIFIED,
      DIGITAL_CAPTURE,
      COMPUTATIONAL_CAPTURE,
      SCREEN_CAPTURE,
      VIRTUAL_RECORDING,
      NEGATIVE_FILM,
      POSITIVE_FILM,
      PRINT,
      HUMAN_EDITS,
      DIGITAL_CREATION,
      ALGORITHMICALLY_ENHANCED,
      DATA_DRIVEN_MEDIA,
      ALGORITHMIC_MEDIA,
      TRAINED_ALGORITHMIC_MEDIA,
      COMPOSITE_WITH_TRAINED_ALGORITHMIC_MEDIA,
      COMPOSITE_SYNTHETIC,
      COMPOSITE,
      COMPOSITE_CAPTURE
    ].freeze
  end
end
