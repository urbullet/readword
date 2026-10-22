# frozen_string_literal: true

module Readword
  Paragraph = Struct.new(:text, :heading, :list, keyword_init: true)
  ListItem = Struct.new(:level, :label, :bullet, :list, keyword_init: true)
  Row = Struct.new(:cells)

  # Writes the readers' paragraphs and table rows as Markdown: headings, nested lists and pipe tables.
  module Markdown
    ORDERED_MARKER = /\A\d{1,9}[.)]\z/
    LITERAL_START = /\A[#>|]/

    module_function

    def render(blocks)
      parts = []
      rows = []
      offsets = []
      blocks.each do |block|
        next rows << block.cells if block.is_a?(Row)

        parts << [:block, table(rows)] if rows.any?
        rows = []
        next if Readword.blank?(block.text)

        if block.list && !block.heading
          offsets.clear unless parts.last && parts.last[2] == block.list.list
          parts << [:item, item(block, offsets), block.list.list]
        else
          offsets.clear
          parts << [:block, block.heading ? heading(block) : escape(block.text.lstrip)]
        end
      end
      parts << [:block, table(rows)] if rows.any?
      join(parts)
    end

    def plain(block)
      return block.cells.join(' | ') if block.is_a?(Row)

      list = block.list
      return block.text unless list

      "#{list.bullet ? '•' : list.label} #{block.text}"
    end

    def join(parts)
      text = +''
      parts.each_with_index do |(kind, chunk, list), index|
        previous_kind, _, previous_list = parts[index - 1]
        text << (kind == :item && previous_kind == :item && list == previous_list ? "\n" : "\n\n") if index.positive?
        text << chunk
      end
      text
    end

    def heading(block)
      label = block.list && !block.list.bullet ? "#{block.list.label} " : ''
      "#{'#' * block.heading} #{label}#{Readword.squish(block.text)}"
    end

    def item(block, offsets)
      list = block.list
      level = list.level
      marker = list.bullet || !ORDERED_MARKER.match?(list.label) ? '-' : list.label
      text = block.text.strip
      text = "#{list.label} #{text}" if marker == '-' && !list.bullet
      indent = (0...level).sum { |parent| offsets[parent] || 2 }
      offsets[level] = marker.size + 1
      offsets.slice!((level + 1)..)
      "#{' ' * indent}#{marker} #{text.gsub("\n", "\n#{' ' * (indent + marker.size + 1)}")}"
    end

    def table(rows)
      width = rows.map(&:size).max
      lines = rows.map do |cells|
        padded = cells.map { |cell| cell.gsub('|', '\|') } + Array.new(width - cells.size, '')
        "| #{padded.join(' | ')} |"
      end
      lines.insert(1, "| #{Array.new(width, '---').join(' | ')} |").join("\n")
    end

    def escape(text)
      LITERAL_START.match?(text) ? "\\#{text}" : text
    end
  end
end
