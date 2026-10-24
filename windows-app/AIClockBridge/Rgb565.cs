using System.Drawing;
using System.Drawing.Imaging;

namespace AIClockBridge;

// Big-endian RGB565 conversions, the wire format the ESP8266 draws directly
// Shared by the music cover and text-strip encoders.
static class Rgb565
{
    /// 32bppArgb bitmap -> big-endian RGB565 bytes, row-major.
    public static byte[] Encode(Bitmap bmp)
    {
        int w = bmp.Width, h = bmp.Height;
        var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly,
                                PixelFormat.Format32bppArgb);
        try
        {
            var out565 = new byte[w * h * 2];
            unsafe
            {
                for (int y = 0; y < h; y++)
                {
                    var row = (byte*)data.Scan0 + y * data.Stride;
                    for (int x = 0; x < w; x++)
                    {
                        byte b = row[x * 4 + 0], g = row[x * 4 + 1], r = row[x * 4 + 2];
                        ushort v = (ushort)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
                        int o = (y * w + x) * 2;
                        out565[o] = (byte)(v >> 8);
                        out565[o + 1] = (byte)(v & 0xFF);
                    }
                }
            }
            return out565;
        }
        finally
        {
            bmp.UnlockBits(data);
        }
    }

    /// Big-endian RGB565 bytes -> 32bppRgb bitmap. `offset` is where the pixel
    /// data starts inside `data` (frames streams carry a 1-byte frame count).
    public static Bitmap Decode(byte[] data, int offset, int w, int h)
    {
        var frameBytes = w * h * 2;
        if (data.Length < offset + frameBytes) return null;
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppRgb);
        var locked = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly,
                                  PixelFormat.Format32bppRgb);
        try
        {
            unsafe
            {
                for (int y = 0; y < h; y++)
                {
                    var row = (byte*)locked.Scan0 + y * locked.Stride;
                    for (int x = 0; x < w; x++)
                    {
                        int src = offset + (y * w + x) * 2;
                        ushort v = (ushort)((data[src] << 8) | data[src + 1]);
                        row[x * 4 + 0] = (byte)((v & 0x1F) << 3);         // B
                        row[x * 4 + 1] = (byte)(((v >> 5) & 0x3F) << 2);  // G
                        row[x * 4 + 2] = (byte)(((v >> 11) & 0x1F) << 3); // R
                        row[x * 4 + 3] = 255;
                    }
                }
            }
        }
        finally
        {
            bmp.UnlockBits(locked);
        }
        return bmp;
    }

    /// Wire format [1 byte frame count][RGB565 big-endian frames...] -> bitmaps.
    public static List<Bitmap> DecodeSpriteFrames(byte[] data, int w, int h)
    {
        var frames = new List<Bitmap>();
        if (data == null || data.Length < 1) return frames;
        int count = data[0];
        var frameBytes = w * h * 2;
        if (count <= 0 || data.Length < 1 + count * frameBytes) return frames;
        for (int f = 0; f < count; f++)
        {
            var bmp = Decode(data, 1 + f * frameBytes, w, h);
            if (bmp != null) frames.Add(bmp);
        }
        return frames;
    }
}
