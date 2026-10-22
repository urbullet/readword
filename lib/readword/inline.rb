# frozen_string_literal: true

module Readword
  # Writes formatted pieces of a paragraph as Markdown: bold, italics and links, opening and closing markers only where the
  # formatting changes, keeping spaces outside the markers and ignoring emphasis that starts or ends inside a word.
  module Inline
    EDGE_SPACE = /\A[[:space:]]+|[[:space:]]+\z/
    LEADING_SPACE = /\A[[:space:]]*/
    TRAILING_SPACE = /[[:space:]]*\z/
    WORD_START = /\A[[:alnum:]]/
    WORD_END = /[[:alnum:]]\z/

    module_function

    def render(spans, bold: true)
      return spans.map(&:text).join unless spans.any? { |span| (bold && span.bold) || span.italic || span.link }

      pieces = merge(spans.map { |span| [span.text, bold && span.bold, span.italic, span.link] })
      pieces = merge(pieces.each_with_index.map { |piece, index| inside_word?(pieces, index) ? [piece[0], false, false, piece[3]] : piece })
      state = [false, false]
      held = +''
      text = +''
      pieces.each do |content, strong, emphasis, link|
        if link
          text << close(state) << held << decorate(content, strong, emphasis, link)
          held = +''
          next
        end
        core = content.gsub(EDGE_SPACE, '')
        next held << content if core.empty?

        core = core.gsub('*', '\\*') if strong || emphasis
        text << switch(state, strong, emphasis, held + content[LEADING_SPACE]) << core
        held = +content[TRAILING_SPACE]
      end
      text << close(state) << held
    end

    def merge(pieces)
      pieces.each_with_object([]) do |piece, merged|
        next merged.last[0] += piece[0] if merged.last && merged.last[1..] == piece[1..]

        merged << [piece[0].dup, *piece[1..]]
      end
    end

    def inside_word?(pieces, index)
      content, strong, emphasis, link = pieces[index]
      return false unless (strong || emphasis) && !link

      before = pieces[index - 1]&.first if index.positive?
      after = pieces[index + 1]&.first
      (before&.match?(WORD_END) && content.match?(WORD_START)) || (after&.match?(WORD_START) && content.match?(WORD_END))
    end

    def switch(state, strong, emphasis, gap)
      bold_open, italic_open = state
      closing = +''
      opening = +''
      if italic_open && (!emphasis || (bold_open && !strong) || (strong && !bold_open))
        closing << '*'
        italic_open = false
      end
      if bold_open && !strong
        closing << '**'
        bold_open = false
      end
      if strong && !bold_open
        opening << '**'
        bold_open = true
      end
      if emphasis && !italic_open
        opening << '*'
        italic_open = true
      end
      state.replace([bold_open, italic_open])
      "#{closing}#{gap}#{opening}"
    end

    def close(state)
      markers = "#{'*' if state[1]}#{'**' if state[0]}"
      state.replace([false, false])
      markers
    end

    def decorate(text, strong, emphasis, link)
      core = text.gsub(EDGE_SPACE, '')
      return text if core.empty? || !(strong || emphasis || link)

      core = core.gsub('*', '\\*') if strong || emphasis
      marker = if strong && emphasis then '***'
               elsif strong then '**'
               elsif emphasis then '*'
               else ''
               end
      core = "#{marker}#{core}#{marker}"
      core = "[#{core}](#{link.match?(/[[:space:]()<>]/) ? "<#{link.delete('<>')}>" : link})" if link
      "#{text[LEADING_SPACE]}#{core}#{text[TRAILING_SPACE]}"
    end
  end
end
