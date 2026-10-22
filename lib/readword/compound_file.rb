# frozen_string_literal: true

module Readword
  # Reads named streams out of a Compound File (MS-CFB), the container every .doc is stored in.
  class CompoundFile
    include Binary

    # Compound File Header: the signature, then fields at fixed byte offsets in the first 512 bytes.
    SIGNATURE = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b.freeze
    HEADER_BYTES = 512
    SECTOR_SHIFT = 0x1E
    MINI_SECTOR_SHIFT = 0x20
    FAT_SECTOR_COUNT = 0x2C
    FIRST_DIRECTORY_SECTOR = 0x30
    MINI_STREAM_CUTOFF = 0x38
    FIRST_MINI_FAT_SECTOR = 0x3C
    FIRST_DIFAT_SECTOR = 0x44
    DIFAT_SECTOR_COUNT = 0x48
    HEADER_DIFAT = 0x4C
    HEADER_DIFAT_BYTES = 436
    # Sector numbers above MAXREGSECT are markers such as ENDOFCHAIN, never real sectors.
    MAX_REGULAR_SECTOR = 0xFFFFFFFA
    # Directory entries are 128 bytes; NOSTREAM marks an empty link and object type 2 is a stream.
    NO_ENTRY = 0xFFFFFFFF
    STREAM = 2
    ENTRY_BYTES = 128

    def initialize(bytes)
      @bytes = bytes.b
      raise Error, UNREADABLE unless @bytes.bytesize >= HEADER_BYTES && @bytes.start_with?(SIGNATURE)

      @sector_size = 1 << u16(@bytes, SECTOR_SHIFT)
      @mini_sector_size = 1 << u16(@bytes, MINI_SECTOR_SHIFT)
      raise Error, UNREADABLE unless [512, 4096].include?(@sector_size) && @mini_sector_size == 64

      @fat = fat_sector_ids.flat_map { |sector_id| words(sector(sector_id)) }
      @directory = chain_data(u32(@bytes, FIRST_DIRECTORY_SECTOR))
      @root = entry(0) || raise(Error, UNREADABLE)
    end

    def stream(name)
      found = root_children.find { |child| child[:type] == STREAM && child[:name].casecmp?(name) }
      found && read(found)
    end

    def stream?(name)
      root_children.any? { |child| child[:type] == STREAM && child[:name].casecmp?(name) }
    end

    private

    # The header holds the first 109 FAT sector numbers; bigger files continue the list in chained DIFAT sectors.
    def fat_sector_ids
      limit = [u32(@bytes, FAT_SECTOR_COUNT), (sector_count / (@sector_size / 4)) + 1].min
      ids = words(@bytes.byteslice(HEADER_DIFAT, HEADER_DIFAT_BYTES))
      next_id = u32(@bytes, FIRST_DIFAT_SECTOR)
      remaining = u32(@bytes, DIFAT_SECTOR_COUNT)
      seen = Set.new
      while remaining.positive? && ids.size < limit && next_id <= MAX_REGULAR_SECTOR && seen.add?(next_id)
        difat = words(sector(next_id))
        ids.concat(difat[0...-1])
        next_id = difat.last.to_i
        remaining -= 1
      end
      ids.first(limit).select { |id| id <= MAX_REGULAR_SECTOR }
    end

    # Directory entries form a tree through their left, right and child links.
    def root_children
      @root_children ||= begin
        pending = [@root[:child]]
        seen = Set.new
        children = []
        until pending.empty?
          id = pending.pop
          next if id == NO_ENTRY || !seen.add?(id)

          child = entry(id) or next
          children << child
          pending.push(child[:left], child[:right])
        end
        children
      end
    end

    def entry(index)
      raw = @directory.byteslice(index * ENTRY_BYTES, ENTRY_BYTES)
      return unless raw&.bytesize == ENTRY_BYTES

      left, right, child = raw.unpack('@68V3')
      { name: entry_name(raw), type: raw.getbyte(66), left: left, right: right, child: child,
        start: raw.unpack1('@116V'), size: raw.unpack1('@120V') }
    end

    def entry_name(raw)
      length = raw.unpack1('@64v').clamp(2, 64) - 2
      raw.byteslice(0, length).force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    # Streams under the mini stream cutoff (4096 bytes) live in 64-byte mini sectors inside the root entry's stream.
    def read(found)
      data = found[:size] < u32(@bytes, MINI_STREAM_CUTOFF) ? mini_chain_data(found[:start]) : chain_data(found[:start])
      data.byteslice(0, found[:size])
    end

    def chain_data(start)
      chain(start, @fat).map { |sector_id| sector(sector_id) }.join
    end

    def mini_chain_data(start)
      chain(start, mini_fat).map { |sector_id| mini_stream.byteslice(sector_id * @mini_sector_size, @mini_sector_size) }.join
    end

    def mini_fat
      @mini_fat ||= chain(u32(@bytes, FIRST_MINI_FAT_SECTOR), @fat).flat_map { |sector_id| words(sector(sector_id)) }
    end

    def mini_stream
      @mini_stream ||= chain_data(@root[:start])
    end

    # Follows a FAT or mini FAT chain; a chain longer than its table can only be a loop in a crafted file.
    def chain(start, table)
      ids = []
      id = start
      while id <= MAX_REGULAR_SECTOR
        raise Error, UNREADABLE if id >= table.size || ids.size >= table.size

        ids << id
        id = table[id]
      end
      ids
    end

    # Sector 0 starts right after the header sector.
    def sector(id)
      @bytes.byteslice((id + 1) * @sector_size, @sector_size) || raise(Error, UNREADABLE)
    end

    def sector_count
      @bytes.bytesize / @sector_size
    end

    def words(bytes)
      bytes.to_s.unpack('V*')
    end
  end
end
