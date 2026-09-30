defmodule Badge.Icons do
  @moduledoc """
  Converted artwork from `assets/icons`, baked into the module at compile time.

  Files are named `<name>@<width>x<height>` with one of two suffixes. `.rgba`
  is straight-alpha `rgba8888` and is drawn as it is. `.mask` is one alpha
  byte per pixel for monochrome art, and is baked here once per tint in
  `tints/0`, so a skin's `glyph/0` picks the colour at draw time without any
  work on the badge. A tint no skin uses costs flash for nothing, and one a
  skin asks for without being listed here draws nothing, which
  `Badge.SkinTest` catches.

  AtomGL blends every pixel that is not fully opaque against the background
  colour the item names, so an icon sits cleanly on any skin.

  Masks listed in `packed/0` are too big to bake per tint. They are kept at
  four bits a pixel and tinted when `binary/2` is called, in any colour, which
  costs a pass over the image each time: a page drawing one should ask once
  and keep the result.

  Shapes are 32x32 and status icons are 16x16, so read `size/1` rather than
  assuming. Regenerate the files with `tools/icons.py`.
  """

  alias Badge.Theme

  @tints [0xFFFFFF, 0x000000]

  @packed [:badge_share]

  @dir Path.expand("../../assets/icons", __DIR__)
  @shapes [:square, :triangle, :cross, :circle, :clover, :diamond]

  File.dir?(@dir) || raise "no icon directory at #{@dir} — run tools/icons.py"

  # The directory itself, so adding or removing an icon recompiles this module.
  # Per-file @external_resource cannot track a file that does not exist yet.
  @external_resource @dir

  @files Enum.sort(Path.wildcard(Path.join(@dir, "*.{rgba,mask}")))

  @files != [] || raise "no icon files in #{@dir} — run tools/icons.py"

  for file <- @files do
    @external_resource file
  end

  # Parsed and checked on the host, where the full standard library is available.
  @icons (for path <- @files, into: %{} do
            kind =
              case Path.extname(path) do
                ".rgba" -> :colour
                ".mask" -> :mask
              end

            base = Path.basename(path, Path.extname(path))

            # Host-only: the names come from a directory in this repo, not from input.
            {name, width, height} =
              case String.split(base, "@") do
                [name, dimensions] ->
                  case String.split(dimensions, "x") do
                    [width, height] ->
                      {String.to_atom(name), String.to_integer(width), String.to_integer(height)}

                    _ ->
                      raise "icon #{base}: expected <name>@<width>x<height>"
                  end

                _ ->
                  raise "icon #{base}: expected <name>@<width>x<height>"
              end

            data = File.read!(path)

            expected =
              case kind do
                :colour -> width * height * 4
                :mask -> width * height
              end

            byte_size(data) == expected ||
              raise "icon #{base}: #{byte_size(data)} bytes, expected #{expected}"

            {name, {width, height, kind, data}}
          end)

  case @shapes -- Map.keys(@icons) do
    [] -> :ok
    missing -> raise "missing shape icons: #{Enum.join(missing, ", ")}"
  end

  @names Enum.sort(Map.keys(@icons))

  @doc "Every icon name, sorted."
  def names, do: @names

  @doc "The colours monochrome icons are baked in."
  def tints, do: @tints

  @doc "The masks kept at four bits a pixel and tinted on request."
  def packed, do: @packed

  @doc "A packed mask's four-bit alpha, two pixels a byte, or nil for any other icon."
  def packed_binary(name)

  for {name, {width, height, :mask, mask}} <- @icons, name in @packed do
    rem(width * height, 2) == 0 || raise "packed icon #{name}: odd pixel count"

    packed = for <<a, b <- mask>>, into: <<>>, do: <<div(a + 8, 17)::4, div(b + 8, 17)::4>>

    def packed_binary(unquote(name)), do: unquote(packed)
  end

  def packed_binary(_name), do: nil

  @doc "Whether an icon is monochrome, and so takes a tint."
  def mono?(name)

  for {name, {_width, _height, kind, _data}} <- @icons do
    def mono?(unquote(name)), do: unquote(kind == :mask)
  end

  def mono?(_name), do: false

  @doc """
  The raw `rgba8888` binary for one icon.

  A monochrome icon comes back in `tint`, which must be one of `tints/0`;
  a colour icon ignores it. `nil` for an unknown icon or an unbaked tint.
  """
  def binary(name, tint)

  for {name, {_width, _height, :colour, data}} <- @icons do
    def binary(unquote(name), _tint), do: unquote(data)
  end

  for name <- @packed do
    def binary(unquote(name), tint), do: expand(packed_binary(unquote(name)), tint)
  end

  for {name, {_width, _height, :mask, mask}} <- @icons, name not in @packed, tint <- @tints do
    r = div(tint, 0x10000)
    g = div(rem(tint, 0x10000), 0x100)
    b = rem(tint, 0x100)
    data = for <<alpha <- mask>>, into: <<>>, do: <<r, g, b, alpha>>

    def binary(unquote(name), unquote(tint)), do: unquote(data)
  end

  def binary(_name, _tint), do: nil

  # One lookup per packed byte: its two pixels, already tinted.
  defp expand(packed, tint) do
    r = div(tint, 0x10000)
    g = div(rem(tint, 0x10000), 0x100)
    b = rem(tint, 0x100)

    pairs =
      :lists.map(
        fn byte -> <<r, g, b, div(byte, 16) * 17, r, g, b, rem(byte, 16) * 17>> end,
        :lists.seq(0, 255)
      )

    table = :erlang.list_to_tuple(pairs)

    :erlang.iolist_to_binary(for <<byte <- packed>>, do: :erlang.element(byte + 1, table))
  end

  @doc "The icon's `{width, height}` in pixels, or nil if there is no such icon."
  def size(name)

  for {name, {width, height, _kind, _data}} <- @icons do
    def size(unquote(name)), do: {unquote(width), unquote(height)}
  end

  def size(_name), do: nil

  @doc "A display item drawing `name` at native size in the skin's glyph colour on its background."
  def item(name, x, y), do: item(name, x, y, Theme.glyph(), Theme.bg())

  @doc "A display item drawing `name` at native size, tinted and blended onto `bg`."
  def item(name, x, y, tint, bg) do
    {width, height} = size(name)

    {:image, x, y, bg, {:rgba8888, width, height, binary(name, tint)}}
  end
end
