# typed: strict
# frozen_string_literal: true

module Subtitles
  # A language's codes (ISO 639): OpenSubtitles and Settings use the
  # two-letter one, and a file's tracks say whichever the muxer did.
  module Languages
    extend T::Sig

    # ISO 639-2, where it has a single code.
    ONE_CODE = T.let({
      "aa" => "aar", "ab" => "abk", "af" => "afr", "ak" => "aka", "am" => "amh", "an" => "arg", "ar" => "ara", "as" => "asm", "av" => "ava",
      "ay" => "aym", "az" => "aze", "ba" => "bak", "be" => "bel", "bg" => "bul", "bi" => "bis", "bm" => "bam", "bn" => "ben", "br" => "bre",
      "bs" => "bos", "ca" => "cat", "ce" => "che", "ch" => "cha", "co" => "cos", "cr" => "cre", "cu" => "chu", "cv" => "chv", "da" => "dan",
      "dv" => "div", "dz" => "dzo", "ee" => "ewe", "en" => "eng", "eo" => "epo", "es" => "spa", "et" => "est", "ff" => "ful", "fi" => "fin",
      "fj" => "fij", "fo" => "fao", "fy" => "fry", "ga" => "gle", "gd" => "gla", "gl" => "glg", "gn" => "grn", "gu" => "guj", "gv" => "glv",
      "ha" => "hau", "he" => "heb", "hi" => "hin", "ho" => "hmo", "hr" => "hrv", "ht" => "hat", "hu" => "hun", "hz" => "her", "ia" => "ina",
      "id" => "ind", "ie" => "ile", "ig" => "ibo", "ii" => "iii", "ik" => "ipk", "io" => "ido", "it" => "ita", "iu" => "iku", "ja" => "jpn",
      "jv" => "jav", "kg" => "kon", "ki" => "kik", "kj" => "kua", "kk" => "kaz", "kl" => "kal", "km" => "khm", "kn" => "kan", "ko" => "kor",
      "kr" => "kau", "ks" => "kas", "ku" => "kur", "kv" => "kom", "kw" => "cor", "ky" => "kir", "la" => "lat", "lb" => "ltz", "lg" => "lug",
      "li" => "lim", "ln" => "lin", "lo" => "lao", "lt" => "lit", "lu" => "lub", "lv" => "lav", "mg" => "mlg", "mh" => "mah", "ml" => "mal",
      "mn" => "mon", "mr" => "mar", "mt" => "mlt", "na" => "nau", "nb" => "nob", "nd" => "nde", "ne" => "nep", "ng" => "ndo", "nn" => "nno",
      "no" => "nor", "nr" => "nbl", "nv" => "nav", "ny" => "nya", "oc" => "oci", "oj" => "oji", "om" => "orm", "or" => "ori", "os" => "oss",
      "pa" => "pan", "pi" => "pli", "pl" => "pol", "ps" => "pus", "pt" => "por", "qu" => "que", "rm" => "roh", "rn" => "run", "ru" => "rus",
      "rw" => "kin", "sa" => "san", "sc" => "srd", "sd" => "snd", "se" => "sme", "sg" => "sag", "si" => "sin", "sl" => "slv", "sm" => "smo",
      "sn" => "sna", "so" => "som", "sr" => "srp", "ss" => "ssw", "st" => "sot", "su" => "sun", "sv" => "swe", "sw" => "swa", "ta" => "tam",
      "te" => "tel", "tg" => "tgk", "th" => "tha", "ti" => "tir", "tk" => "tuk", "tl" => "tgl", "tn" => "tsn", "to" => "ton", "tr" => "tur",
      "ts" => "tso", "tt" => "tat", "tw" => "twi", "ty" => "tah", "ug" => "uig", "uk" => "ukr", "ur" => "urd", "uz" => "uzb", "ve" => "ven",
      "vi" => "vie", "vo" => "vol", "wa" => "wln", "wo" => "wol", "xh" => "xho", "yi" => "yid", "yo" => "yor", "za" => "zha", "zu" => "zul"
    }.freeze, T::Hash[String, String])

    # ISO 639-2's bibliographic and terminology codes, where they differ.
    TWO_CODES = T.let({
      "bo" => %w[tib bod], "cs" => %w[cze ces], "cy" => %w[wel cym], "de" => %w[ger deu], "el" => %w[gre ell], "eu" => %w[baq eus],
      "fa" => %w[per fas], "fr" => %w[fre fra], "hy" => %w[arm hye], "is" => %w[ice isl], "ka" => %w[geo kat], "mi" => %w[mao mri],
      "mk" => %w[mac mkd], "ms" => %w[may msa], "my" => %w[bur mya], "nl" => %w[dut nld], "ro" => %w[rum ron], "sk" => %w[slo slk],
      "sq" => %w[alb sqi], "zh" => %w[chi zho]
    }.freeze, T::Hash[String, T::Array[String]])

    # Every way of writing a language. A region is the language it's of.
    sig { params(code: String).returns(T::Array[String]) }
    def self.codes(code)
      base = base(code)
      [ base, ONE_CODE[base], *TWO_CODES[base] ].compact
    end

    sig { params(wanted: String, track: T.nilable(String)).returns(T::Boolean) }
    def self.same?(wanted, track)
      return false if track.blank?

      codes(wanted).include?(base(track))
    end

    sig { params(code: String).returns(String) }
    def self.base(code) = code.to_s.downcase.split(/[-_]/).first.to_s
    private_class_method :base
  end
end
