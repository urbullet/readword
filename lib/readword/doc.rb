# frozen_string_literal: true

module Readword
  # Reads the text of a Word 97 to 2003 .doc (MS-DOC) from its WordDocument and table streams.
  class Doc
    include Binary

    Piece = Struct.new(:start, :finish, :offset, :compressed)
    Run = Struct.new(:start, :finish, :flags)

    # FibBase: wIdent is always 0xA5EC, and an nFib below 106 means Word 6 or 95.
    WORD_IDENT = 0xA5EC
    FIRST_WORD97_VERSION = 106
    # Byte offsets into the FIB, the header at the start of the WordDocument stream (FibBase, FibRgFcLcb97).
    FIB_VERSION = 0x02
    FIB_FLAGS = 0x0A
    FIB_STYLES = 0x00A2
    FIB_STYLES_BYTES = 0x00A6
    FIB_CHPX_TABLE = 0x00FA
    FIB_CHPX_TABLE_BYTES = 0x00FE
    FIB_PAPX_TABLE = 0x0102
    FIB_PAPX_TABLE_BYTES = 0x0106
    FIB_FONT_TABLE = 0x0112
    FIB_FONT_TABLE_BYTES = 0x0116
    FIB_PIECE_TABLE = 0x01A2
    FIB_PIECE_TABLE_BYTES = 0x01A6
    FIB_LISTS = 0x02E2
    FIB_LISTS_BYTES = 0x02E6
    FIB_LIST_OVERRIDES = 0x02EA
    FIB_LIST_OVERRIDES_BYTES = 0x02EE
    FIB_MIN_BYTES = 0x01AA
    # FibBase flag bits fEncrypted and fWhichTblStm (set means the 1Table stream).
    ENCRYPTED = 0x0100
    TABLE_STREAM_ONE = 0x0200
    # FcCompressed: bit 30 set means 8-bit Windows-1252 text stored at half the offset.
    COMPRESSED_TEXT = 0x40000000
    TEXT_OFFSET = 0x3FFFFFFF
    # Formatting is stored in 512-byte FKP pages of at most 29 paragraph runs or 101 character runs.
    PAGE_BYTES = 512
    MAX_PAPX_RUNS_PER_PAGE = 0x1D
    MAX_CHPX_RUNS_PER_PAGE = 0x65
    # Limits against crafted files, so the reader cannot be made to work forever.
    MAX_PROPERTY_BYTES = 8 * 1024 * 1024
    MAX_TEXT_POSITIONS = 400_000
    NO_FLAGS = {}.freeze

    # Paragraph sprms: in a table, end of a table row, and the same two for a table nested in a cell.
    PARAGRAPH_SPRMS = { 0x2416 => :in_table, 0x2417 => :row_end, 0x244B => :inner_cell, 0x244C => :inner_row_end }.freeze
    # sprmCFRMarkDel: deleted with Track Changes. Word writes 1, or 0x81, a ToggleOperand meaning the opposite of the style.
    DELETED = 0x0800
    DELETED_VALUES = [0x01, 0x81].freeze
    # sprmCSymbol: Insert Symbol stores "(" in the text, and the font number and real character here.
    SYMBOL = 0x6A09
    SYMBOL_PLACEHOLDER = '('
    # FFN, one font in the SttbfFfn table: its name starts after 40 bytes of size, flags, weight, charset, panose and signature.
    FONT_NAME_OFFSET = 40
    # sprmPItap (table depth), sprmPHugePapx (properties kept in the Data stream), and two sprms with unusual operand sizes.
    TABLE_DEPTH = 0x6649
    HUGE_PAPX = 0x6646
    DEFINE_TABLE = 0xD608
    CHANGE_TABS = 0xC615
    # sprmPOutLvl (outline level, 9 is body text), sprmPIlvl (list level) and sprmPIlfo (1-based index into the PlfLfo).
    OUTLINE_LEVEL = 0x2640
    LIST_LEVEL = 0x260A
    LIST = 0x460B
    # STSH: a Stshi (cstd, cbSTDBaseInFile), then one LPStd per style; StdfBase packs sti, stk, istdBase and cupx.
    PARAGRAPH_STYLE = 1
    NO_STYLE = 0x0FFF
    TITLE_STYLE = 62
    MAX_STYLE_DEPTH = 16
    # PlfLst: 28-byte LSTF records, then each list's LVLs (a 28-byte LVLF, its grpprls, then the number text);
    # PlfLfo: 16-byte LFO records, then each LFO's LFOLVL overrides. nfc picks the number style.
    LIST_RECORD_BYTES = 28
    LEVEL_RECORD_BYTES = 28
    OVERRIDE_RECORD_BYTES = 16
    MAX_LISTS = 2048
    NUMBER_FORMATS = { 1 => :upper_roman, 2 => :lower_roman, 3 => :upper_letter, 4 => :lower_letter, 5 => :ordinal,
                       22 => :decimal_zero, 23 => :bullet, 255 => :none }.freeze

    # Special characters in the text: field begin, separator and end, the cell mark, the paragraph mark, and page and column breaks.
    FIELD_BEGIN = "\u0013"
    FIELD_SEPARATOR = "\u0014"
    FIELD_END = "\u0015"
    CELL_MARK = "\a"
    PARAGRAPH_MARK = "\r"
    PARAGRAPH_ENDS = ["\f", "\u000E"].freeze
    REPLACEMENTS = { "\v" => "\n", "\t" => "\t", "\u001E" => '-', "\u00A0" => ' ' }.freeze
    CP1252 = Array.new(256) do |byte|
      byte.chr.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8, undef: :replace, replace: '')
    end.freeze

    def initialize(bytes)
      @file = CompoundFile.new(bytes)
      @word = @file.stream('WordDocument').to_s
      raise Error, PASSWORD_PROTECTED if @word.empty? && @file.stream?('EncryptedPackage')
      raise Error, OLD_FORMAT if u16(@word, FIB_VERSION).to_i.between?(1, FIRST_WORD97_VERSION - 1)
      raise Error, UNREADABLE unless @word.bytesize >= FIB_MIN_BYTES && u16(@word, 0) == WORD_IDENT
      raise Error, PASSWORD_PROTECTED if fib_flags.anybits?(ENCRYPTED)

      @table = @file.stream(fib_flags.anybits?(TABLE_STREAM_ONE) ? '1Table' : '0Table') || raise(Error, UNREADABLE)
    end

    def blocks
      pieces = text_pieces
      raise Error, TOO_LONG if pieces.sum { |piece| [piece.finish - piece.start, 0].max } > MAX_TEXT_POSITIONS

      @property_bytes = 0
      @runs = paragraph_runs
      @marked = marked_runs
      @blocks = []
      @counter = Numbering.new
      @chains = {}
      @paragraph_start = 0
      @row = []
      @text = +''
      read_characters(pieces)
      if @row.any?
        end_row
      else
        @blocks << Paragraph.new(text: @text)
      end
      @blocks
    end

    private

    # Field codes sit between a field begin and its separator; only the result after the separator is text.
    def read_characters(pieces)
      fields = []
      code_depth = 0
      each_character(pieces) do |character, offset, width|
        marks = @marked.empty? ? {} : run_flags(@marked, offset)
        next if marks[:deleted]

        character = font_symbol(*marks[:symbol]) if marks[:symbol] && character == SYMBOL_PLACEHOLDER
        case character
        when FIELD_BEGIN
          fields.push(:code)
          code_depth += 1
        when FIELD_SEPARATOR
          if fields.last == :code
            fields[-1] = :result
            code_depth -= 1
          end
        when FIELD_END
          code_depth -= 1 if fields.pop == :code
        else
          read_character(character, offset, width) if code_depth.zero?
        end
      end
    end

    # A page or column break ends its paragraph only when it closes the paragraph's run, as a section break does.
    def read_character(character, offset, width)
      if character == CELL_MARK
        flags = paragraph_flags(offset)
        flags[:row_end] ? end_row : end_cell(flags)
      elsif character == PARAGRAPH_MARK || (PARAGRAPH_ENDS.include?(character) && paragraph_end?(offset, width))
        end_paragraph(paragraph_flags(offset))
      elsif PARAGRAPH_ENDS.include?(character)
        @text << "\n"
      elsif character >= ' ' || REPLACEMENTS.key?(character)
        @text << REPLACEMENTS.fetch(character, character)
      end
    end

    def end_paragraph(flags)
      if flags[:inner_row_end] then end_row
      elsif flags[:inner_cell] then end_cell(flags)
      elsif flags[:in_table]
        label_paragraph(flags)
        @text << ' '
        @paragraph_start = @text.size
      else
        end_row if @row.any?
        @blocks << Paragraph.new(text: @text, heading: heading_level(flags), list: list_item(flags))
        @text = +''
        @paragraph_start = 0
      end
    end

    def end_cell(flags = nil)
      label_paragraph(flags) if flags
      @row << Readword.squish(@text)
      @text = +''
      @paragraph_start = 0
    end

    def end_row
      end_cell unless Readword.blank?(@text)
      @blocks << Row.new(@row) unless @row.all? { |cell| Readword.blank?(cell) }
      @row = []
      @text = +''
      @paragraph_start = 0
    end

    def label_paragraph(flags)
      item = list_item(flags) or return
      @text.insert(@paragraph_start, "#{item.bullet ? '•' : item.label} ")
    end

    def heading_level(flags)
      chain = style_chain(flags[:style])
      outline = flags[:outline] || chain.filter_map { |style| style[:properties][:outline] }.first
      level = outline || (0 if chain.first&.fetch(:sti) == TITLE_STYLE) ||
              chain.filter_map { |style| style[:sti] - 1 if style[:sti].between?(1, 9) }.first
      [level + 1, 6].min if level&.between?(0, 8)
    end

    def list_item(flags)
      chain = style_chain(flags[:style])
      ilfo = flags[:list] || chain.filter_map { |style| style[:properties][:list] }.first
      level = flags[:list_level] || chain.filter_map { |style| style[:properties][:list_level] }.first
      list = lists[ilfo] if ilfo&.between?(1, MAX_LISTS) && level.to_i.between?(0, 8)
      list && @counter.next_item(list[:key], list[:levels], level.to_i, list[:starts])
    end

    def style_chain(istd)
      @chains[istd] ||= begin
        chain = []
        while istd && istd != NO_STYLE && (style = styles[istd]) && chain.size < MAX_STYLE_DEPTH && !chain.include?(style)
          chain << style
          istd = style[:base]
        end
        chain
      end
    end

    def styles
      @styles ||= begin
        sheet = @table.byteslice(u32(@word, FIB_STYLES).to_i, u32(@word, FIB_STYLES_BYTES).to_i).to_s
        base_bytes = u16(sheet, 4).to_i
        position = 2 + u16(sheet, 0).to_i
        Array.new(u16(sheet, 2).to_i) do
          size = u16(sheet, position).to_i
          style = paragraph_style(sheet.byteslice(position + 2, size).to_s, base_bytes)
          position += 2 + size
          style
        end
      end
    end

    # STD: StdfBase, the style name (a count, the UTF-16 characters and a terminator), then UpxPapx (istd and grpprl).
    def paragraph_style(std, base_bytes)
      return unless base_bytes.between?(10, std.bytesize) && (u16(std, 2) & 0x000F) == PARAGRAPH_STYLE

      upx_at = base_bytes + 4 + (2 * u16(std, base_bytes).to_i)
      upx_bytes = u16(std, upx_at).to_i
      papx = u16(std, 4).anybits?(0x000F) && upx_bytes >= 2 ? std.byteslice(upx_at + 4, upx_bytes - 2).to_s : ''
      { sti: u16(std, 0) & 0x0FFF, base: u16(std, 2) >> 4, properties: sprm_flags(papx) }
    end

    def lists
      @lists ||= list_overrides(list_definitions)
    end

    def list_definitions
      at = u32(@word, FIB_LISTS).to_i
      return {} unless u32(@word, FIB_LISTS_BYTES).to_i.positive?

      count = [u16(@table, at).to_i, MAX_LISTS].min
      position = at + 2 + (LIST_RECORD_BYTES * count)
      Array.new(count) do |index|
        record = @table.byteslice(at + 2 + (LIST_RECORD_BYTES * index), LIST_RECORD_BYTES).to_s
        levels = {}
        (record.getbyte(26).to_i.anybits?(0x01) ? 1 : 9).times do |level|
          definition, position = list_level(position)
          break unless definition

          levels[level] = definition
        end
        [u32(record, 0), levels]
      end.to_h
    end

    def list_overrides(definitions)
      at = u32(@word, FIB_LIST_OVERRIDES).to_i
      return {} unless u32(@word, FIB_LIST_OVERRIDES_BYTES).to_i.positive?

      count = [u32(@table, at).to_i, MAX_LISTS].min
      position = at + 4 + (OVERRIDE_RECORD_BYTES * count)
      (1..count).to_h do |ilfo|
        record = @table.byteslice(at + 4 + (OVERRIDE_RECORD_BYTES * (ilfo - 1)), OVERRIDE_RECORD_BYTES).to_s
        lsid = u32(record, 0)
        levels = definitions.fetch(lsid, {})
        starts = {}
        position += 4
        record.getbyte(12).to_i.times do
          start = @table.byteslice(position, 4).to_s.unpack1('l<')
          options = u32(@table, position + 4).to_i
          position += 8
          starts[options & 0x0F] = start if start && options.anybits?(0x10)
          next unless options.anybits?(0x20)

          definition, position = list_level(position)
          levels = levels.merge(options & 0x0F => definition) if definition
        end
        [ilfo, { key: starts.empty? ? "list #{lsid}" : "override #{ilfo}", levels: levels, starts: starts }]
      end
    end

    # LVL: an LVLF (iStartAt, nfc, ..., cbGrpprlChpx, cbGrpprlPapx), both grpprls, then the number text, whose characters 0 to 8
    # stand for the numbers of those levels.
    def list_level(position)
      record = @table.byteslice(position, LEVEL_RECORD_BYTES)
      return [nil, position] unless record&.bytesize == LEVEL_RECORD_BYTES

      text_at = position + LEVEL_RECORD_BYTES + record.getbyte(24) + record.getbyte(25)
      count = u16(@table, text_at).to_i
      units = @table.byteslice(text_at + 2, 2 * count).to_s.unpack('v*').grep_v(0xD800..0xDFFF)
      template = units.slice_when { |first, second| first < 9 || second < 9 }.map { |group| group.first < 9 ? group.first : group.pack('U*') }
      [Numbering::Level.new(start: record.unpack1('l<'), format: NUMBER_FORMATS.fetch(record.getbyte(4), :decimal), template: template),
       text_at + 2 + (2 * count)]
    end

    def each_character(pieces, &)
      pieces.each do |piece|
        count = piece.finish - piece.start
        next unless count.positive?

        if piece.compressed
          @word.byteslice(piece.offset, count).to_s.each_byte.with_index { |byte, index| yield CP1252[byte], piece.offset + index, 1 }
        else
          each_utf16(@word.byteslice(piece.offset, count * 2).to_s.unpack('v*'), piece.offset, &)
        end
      end
    end

    def each_utf16(units, offset)
      index = 0
      while index < units.size
        unit = units[index]
        low = units[index + 1].to_i
        if unit.between?(0xD800, 0xDBFF) && low.between?(0xDC00, 0xDFFF)
          yield (0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)).chr(Encoding::UTF_8), offset + (2 * index), 4
          index += 1
        elsif !unit.between?(0xD800, 0xDFFF)
          yield unit.chr(Encoding::UTF_8), offset + (2 * index), 2
        end
        index += 1
      end
    end

    # Clx: optional Prc entries (clxt 1), then a Pcdt (clxt 2) whose PlcPcd lists where each run of text is stored.
    def text_pieces
      clx = @table.byteslice(u32(@word, FIB_PIECE_TABLE), u32(@word, FIB_PIECE_TABLE_BYTES)).to_s
      position = 0
      position += 3 + u16(clx, position + 1) while clx.getbyte(position) == 0x01
      raise Error, UNREADABLE unless clx.getbyte(position) == 0x02

      table = clx.byteslice(position + 5, u32(clx, position + 1).to_i).to_s
      count = (table.bytesize - 4) / 12
      raise Error, UNREADABLE unless count.positive?
      raise Error, TOO_LONG if count > MAX_TEXT_POSITIONS

      positions = table.unpack("V#{count + 1}")
      Array.new(count) do |index|
        fc = u32(table, (4 * (count + 1)) + (8 * index) + 2)
        compressed = fc.anybits?(COMPRESSED_TEXT)
        offset = fc & TEXT_OFFSET
        Piece.new(positions[index], positions[index + 1], compressed ? offset / 2 : offset, compressed)
      end
    end

    def paragraph_runs
      runs = []
      property_pages(FIB_PAPX_TABLE, FIB_PAPX_TABLE_BYTES).each do |offset|
        runs.concat(page_runs(offset))
        raise Error, TOO_LONG if runs.size > MAX_TEXT_POSITIONS
      end
      runs.sort_by(&:start)
    end

    def marked_runs
      runs = []
      property_pages(FIB_CHPX_TABLE, FIB_CHPX_TABLE_BYTES).each do |offset|
        runs.concat(character_runs(offset).select { |run| run.flags[:deleted] || run.flags[:symbol] })
        raise Error, TOO_LONG if runs.size > MAX_TEXT_POSITIONS
      end
      runs.sort_by(&:start)
    end

    # PlcBtePapx and PlcBteChpx: FC boundaries, then the FKP page numbers in the low 22 bits.
    def property_pages(table_at, bytes_at)
      table = @table.byteslice(u32(@word, table_at), u32(@word, bytes_at)).to_s
      count = (table.bytesize - 4) / 8
      return [] unless count.positive?

      limit = [count, @word.bytesize / PAGE_BYTES].min
      table.unpack("@#{4 * (count + 1)}V#{limit}").map { |page| (page & 0x3FFFFF) * PAGE_BYTES }.uniq
    end

    # PapxFkp: run boundaries, then 13-byte BxPap entries whose first byte, doubled, points at the run's PapxInFkp.
    def page_runs(offset)
      page = @word.byteslice(offset, PAGE_BYTES).to_s
      return [] unless page.bytesize == PAGE_BYTES

      count = page.getbyte(PAGE_BYTES - 1)
      return [] unless count.between?(1, MAX_PAPX_RUNS_PER_PAGE)

      bounds = page.unpack("V#{count + 1}")
      properties = {}
      Array.new(count) do |index|
        at = page.getbyte((4 * (count + 1)) + (13 * index)) * 2
        Run.new(bounds[index], bounds[index + 1], at.zero? ? NO_FLAGS : (properties[at] ||= papx_flags(page, at)))
      end
    end

    # ChpxFkp: run boundaries, then 1-byte offsets that, doubled, point at each run's Chpx.
    def character_runs(offset)
      page = @word.byteslice(offset, PAGE_BYTES).to_s
      return [] unless page.bytesize == PAGE_BYTES

      count = page.getbyte(PAGE_BYTES - 1)
      return [] unless count.between?(1, MAX_CHPX_RUNS_PER_PAGE)

      bounds = page.unpack("V#{count + 1}")
      properties = {}
      Array.new(count) do |index|
        at = page.getbyte((4 * (count + 1)) + index) * 2
        Run.new(bounds[index], bounds[index + 1], at.zero? ? NO_FLAGS : (properties[at] ||= chpx_flags(page, at)))
      end
    end

    # PapxInFkp: a size byte (0 means the next byte holds it), then a 2-byte style index and the sprms.
    def papx_flags(page, offset)
      size = page.getbyte(offset) or return {}
      length, start = size.zero? ? [2 * page.getbyte(offset + 1).to_i, offset + 2] : [(2 * size) - 1, offset + 1]
      sprm_flags(page.byteslice(start + 2, length - 2).to_s).merge(style: u16(page, start))
    end

    def chpx_flags(page, offset)
      size = page.getbyte(offset) or return {}
      sprm_flags(page.byteslice(offset + 1, size).to_s)
    end

    def sprm_flags(grpprl, nested: false)
      @property_bytes += grpprl.bytesize
      raise Error, UNREADABLE if @property_bytes > MAX_PROPERTY_BYTES

      flags = {}
      position = 0
      while position + 2 <= grpprl.bytesize
        sprm = u16(grpprl, position)
        size = operand_size(sprm, grpprl, position + 2) or break
        operand = grpprl.byteslice(position + 2, size).to_s
        if PARAGRAPH_SPRMS.key?(sprm) then flags[PARAGRAPH_SPRMS[sprm]] = operand.getbyte(0) == 1
        elsif sprm == DELETED then flags[:deleted] = DELETED_VALUES.include?(operand.getbyte(0))
        elsif sprm == SYMBOL then flags[:symbol] = [u16(operand, 0).to_i, u16(operand, 2).to_i]
        elsif sprm == OUTLINE_LEVEL then flags[:outline] = operand.getbyte(0)
        elsif sprm == LIST_LEVEL then flags[:list_level] = operand.getbyte(0)
        elsif sprm == LIST then flags[:list] = u16(operand, 0)
        elsif sprm == TABLE_DEPTH then flags[:in_table] ||= u32(operand, 0).to_i.positive?
        elsif sprm == HUGE_PAPX && !nested then flags.merge!(huge_papx_flags(u32(operand, 0).to_i))
        end
        position += 2 + size
      end
      flags
    end

    # The sprm's top 3 bits (spra) give its operand size; 6 means the size is stored in the operand itself.
    def operand_size(sprm, grpprl, offset)
      case sprm >> 13
      when 0, 1 then 1
      when 2, 4, 5 then 2
      when 3 then 4
      when 7 then 3
      else variable_operand_size(sprm, grpprl, offset)
      end
    end

    def variable_operand_size(sprm, grpprl, offset)
      return u16(grpprl, offset).to_i + 1 if sprm == DEFINE_TABLE

      size = grpprl.getbyte(offset) or return
      size + 1 unless sprm == CHANGE_TABS && size == 255
    end

    def huge_papx_flags(offset)
      @huge_papx ||= {}
      @huge_papx[offset] ||= begin
        @data ||= @file.stream('Data').to_s
        size = u16(@data, offset)
        size ? sprm_flags(@data.byteslice(offset + 2, size).to_s, nested: true) : {}
      end
    end

    def paragraph_end?(offset, width)
      index = (@runs.bsearch_index { |run| run.start > offset } || @runs.size) - 1
      index >= 0 && @runs[index].finish == offset + width
    end

    def paragraph_flags(offset)
      run_flags(@runs, offset)
    end

    def run_flags(runs, offset)
      index = (runs.bsearch_index { |run| run.start > offset } || runs.size) - 1
      return {} if index.negative?

      run = runs[index]
      offset < run.finish ? run.flags : {}
    end

    def font_symbol(font, code)
      Readword.symbol(font_names[font], code)
    end

    def font_names
      @font_names ||= begin
        table = @table.byteslice(u32(@word, FIB_FONT_TABLE), u32(@word, FIB_FONT_TABLE_BYTES)).to_s
        position = 4
        Array.new(u16(table, 0).to_i) do
          size = table.getbyte(position).to_i + 1
          name = table.byteslice(position + FONT_NAME_OFFSET, size - FONT_NAME_OFFSET).to_s
          position += size
          name.unpack('v*').take_while(&:nonzero?).pack('U*').scrub('')
        end
      end
    end

    def fib_flags
      u16(@word, FIB_FLAGS)
    end
  end
end
