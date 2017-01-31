require "base64"

# Defines the padding to use based on the SHA-3 function domain.
class Domain
  SHA3  = 6u8
  SHAKE = 1u8 # Keccak[3]
end

class Digest::SHA3
  def self.digest(string : String) : Bytes
    digest(string.to_slice)
  end

  def self.digest(slice : Bytes) : Bytes
    context = self.new
    context.update(slice)
    context.result
  end

  def self.hexdigest(string_or_slice : String | Bytes) : String
    digest(string_or_slice).to_slice.hexstring
  end

  def self.base64digest(string_or_slice : String | Bytes) : String
    Base64.strict_encode(digest(string_or_slice).to_slice)
  end

  def hexdigest : String
    result.to_slice.hexstring
  end

  HASH_SIZES = [224, 256, 384, 512]

  DOMAIN = Domain::SHA3

  RNDC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a,
    0x8000000080008000, 0x000000000000808b, 0x0000000080000001,
    0x8000000080008081, 0x8000000000008009, 0x000000000000008a,
    0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089,
    0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
    0x000000000000800a, 0x800000008000000a, 0x8000000080008081,
    0x8000000000008080, 0x0000000080000001, 0x8000000080008008
  ]

  ROTC = [
    1,  3,  6,  10, 15, 21, 28, 36, 45, 55, 2,  14,
    27, 41, 56, 8,  25, 43, 62, 18, 39, 61, 20, 44
  ]

  PILN = [
    10, 7,  11, 17, 18, 3, 5,  16, 8,  21, 24, 4,
    15, 23, 19, 13, 12, 2, 20, 14, 22, 9,  6,  1
  ]

  def initialize(hash_size = 512)
    unless HASH_SIZES.includes? hash_size
      raise "Invalid hash size: #{hash_size}. Must be one of #{HASH_SIZES.join(',')}"
    end

    @input = uninitialized Bytes
    @buffer = Slice(UInt32).new(25)
    @size = UInt32.new(hash_size / 8)
  end

  def update(s : String)
    update(s.to_slice)
  end

  def update(s : Bytes)
    @input = s
    self
  end

  def reset
    @buffer.clear
    self
  end

  def result
    state = Slice(UInt64).new(25)
    width = 200 - @size * 2

    padding_size  = width - @input.size % width
    buffer_size   = @input.size + padding_size

    # Initialize and fill buffer with the input string
    buffer = Slice(UInt8).new(buffer_size)
    buffer.copy_from(@input.pointer(0), @input.size)

    # Set the first padded bit
    # Regarding the assignment: https://github.com/crystal-lang/crystal/issues/3241
    buffer[@input.size] = {% begin %}{{@type.id}}::DOMAIN{% end %}

    # Zero-pad the buffer up to the message width
    (buffer.to_unsafe + @input.size + 1).clear(padding_size)

    # Set the final bit of padding to 0x80
    buffer[buffer_size-1] = (buffer[buffer_size-1] | 0x80)

    state_size = width / 8
    (0..buffer_size-1).step(width) do |j|
      quads = buffer[j, width].to_unsafe.as(UInt64*).to_slice(state_size)
      state_size.times do |i|
        state[i] ^= quads[i]
      end

      keccak(state)
    end

    # Return the result
    state.to_unsafe.as(UInt8*).to_slice(@size)
  end

  private def keccak(state : Slice(UInt64))
    lanes = Slice(UInt64).new(5)

    24.times do |round|
      # Theta
      lanes[0] = state[0] ^ state[5] ^ state[10] ^ state[15] ^ state[20]
      lanes[1] = state[1] ^ state[6] ^ state[11] ^ state[16] ^ state[21]
      lanes[2] = state[2] ^ state[7] ^ state[12] ^ state[17] ^ state[22]
      lanes[3] = state[3] ^ state[8] ^ state[13] ^ state[18] ^ state[23]
      lanes[4] = state[4] ^ state[9] ^ state[14] ^ state[19] ^ state[24]

      (0..4).each do |i|
        t = lanes[(i + 4) % 5] ^ rotl64(lanes[(i + 1) % 5], 1)
        state[i     ] ^= t
        state[i +  5] ^= t
        state[i + 10] ^= t
        state[i + 15] ^= t
        state[i + 20] ^= t
      end

      # Rho Pi
      t = state[1]
      24.times do |i|
        lanes[0] = state[PILN[i]]
        state[PILN[i]] = rotl64(t, ROTC[i])
        t = lanes[0]
      end

      # Chi
      (0..24).step(5) do |j|
        lanes[0] = state[j    ]
        lanes[1] = state[j + 1]
        lanes[2] = state[j + 2]
        lanes[3] = state[j + 3]
        lanes[4] = state[j + 4]
        state[j    ] ^= (~lanes[1]) & lanes[2]
        state[j + 1] ^= (~lanes[2]) & lanes[3]
        state[j + 2] ^= (~lanes[3]) & lanes[4]
        state[j + 3] ^= (~lanes[4]) & lanes[0]
        state[j + 4] ^= (~lanes[0]) & lanes[1]
      end

      # Iota
      state[0] ^= RNDC[round]
    end
  end

  private def rotl64(x : UInt64, y : Int32)
    (x << y | x >> 64 - y) & (1 << 64) - 1
  end
end

class Digest::Keccak3 < Digest::SHA3
  DOMAIN = Domain::SHAKE
end