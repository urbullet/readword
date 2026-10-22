# frozen_string_literal: true

module Readword
  # Little-endian number readers for the binary Office formats (MS-CFB, MS-DOC).
  # They return nil past the end of the data, so a crafted offset reads as missing instead of raising.
  module Binary
    private

    def u16(bytes, offset)
      bytes.unpack1('v', offset: offset) if offset + 2 <= bytes.bytesize
    end

    def u32(bytes, offset)
      bytes.unpack1('V', offset: offset) if offset + 4 <= bytes.bytesize
    end
  end
end
