const zstbi = @import("zstbi");

/// Flips an image horizontally (mirrors left-right).
/// Modifies the image data in place.
pub fn flipImageHorizontal(image: *zstbi.Image) void {
    const width = image.width;
    const height = image.height;
    const channels = image.num_components;
    const row_size = width * channels;

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width / 2) : (x += 1) {
            const left_idx = y * row_size + x * channels;
            const right_idx = y * row_size + (width - 1 - x) * channels;

            var c: usize = 0;
            while (c < channels) : (c += 1) {
                const temp = image.data[left_idx + c];
                image.data[left_idx + c] = image.data[right_idx + c];
                image.data[right_idx + c] = temp;
            }
        }
    }
}
