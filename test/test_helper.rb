# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'minitest/autorun'
require 'stringio'
require 'timeout'
require 'readword'

module Minitest
  class Test
    def self.test(name, &)
      define_method("test_#{name.gsub(/\s+/, '_')}", &)
    end
  end
end

module WordDocumentHelper
  FIXTURES = File.expand_path('fixtures', __dir__)
  WORD_HEADER = "\xEC\xA5\xC1\x00".b.freeze

  def fixture(name)
    File.binread(File.join(FIXTURES, name))
  end

  def lims_report_doc
    fixture('lims_report.doc')
  end

  def password_protected_lims_report_doc
    lims_report_doc.tap do |bytes|
      flags = bytes.index(WORD_HEADER) + 0x0B
      bytes.setbyte(flags, bytes.getbyte(flags) | 0x01)
    end
  end

  def zip_with(entries)
    Zip::OutputStream.write_buffer do |out|
      entries.each do |name, content|
        out.put_next_entry(name)
        out.write(content)
      end
    end.string
  end
end
