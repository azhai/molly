package backend

// file_md5 —— 纯 Odin 的 MD5（RFC 1321）。
//
// core:hash 只有 crc/murmur/xxhash，没有 MD5；而 rpc_file_md5（file.c:561-592）算的正是
// MD5 十六进制。自带一份保证 darwin/linux 两端逐字节一致，且不依赖 OpenSSL。

// md5_s：每轮的左旋转量；md5_k：K[i] = floor(2^32 * |sin(i+1)|)。
md5_s := [64]int{
	7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
	5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
	4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
	6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

md5_k := [64]u32{
	0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
	0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
	0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
	0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
	0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
	0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
	0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
	0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
	0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
	0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
	0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
	0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
	0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
	0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
	0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
	0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

md5_rol :: proc(x: u32, c: int) -> u32 {
	return (x << cast(u32)c) | (x >> cast(u32)(32 - c))
}

// md5_hex —— 返回 data 的 32 位小写十六进制 MD5（对齐 Go fmt.Sprintf("%x", md5.Sum)）。
// 临时缓冲走 context.allocator（调用方已置为每入站调用的 arena）。
md5_hex :: proc(data: []u8) -> string {
	a0: u32 = 0x67452301
	b0: u32 = 0xefcdab89
	c0: u32 = 0x98badcfe
	d0: u32 = 0x10325476

	// 填充：0x80 + 若干 0 使 (len % 64 == 56)，再追加 64 位小端比特长度。
	total := len(data) + 1
	for total % 64 != 56 {
		total += 1
	}
	total += 8
	buf := make([]u8, total)
	for i := 0; i < total; i += 1 {
		buf[i] = 0
	}
	copy(buf, data)
	buf[len(data)] = 0x80
	bits := cast(u64)len(data) * 8
	for i := 0; i < 8; i += 1 {
		buf[total-8+i] = cast(u8)(bits >> cast(u64)(i*8))
	}

	block: [16]u32
	for off := 0; off < total; off += 64 {
		for j := 0; j < 16; j += 1 {
			base := off + j*4
			block[j] = cast(u32)buf[base] |
				(cast(u32)buf[base+1] << 8) |
				(cast(u32)buf[base+2] << 16) |
				(cast(u32)buf[base+3] << 24)
		}
		a, b, c, d := a0, b0, c0, d0
		for i := 0; i < 64; i += 1 {
			f: u32
			g: int
			if i < 16 {
				f = (b & c) | (~b & d)
				g = i
			} else if i < 32 {
				f = (d & b) | (~d & c)
				g = (5*i + 1) % 16
			} else if i < 48 {
				f = b ~ c ~ d
				g = (3*i + 5) % 16
			} else {
				f = c ~ (b | ~d)
				g = (7*i) % 16
			}
			tmp := d
			d = c
			c = b
			b = b + md5_rol(a + f + md5_k[i] + block[g], md5_s[i])
			a = tmp
		}
		a0 += a
		b0 += b
		c0 += c
		d0 += d
	}

	out: [16]u8
	words := [4]u32{a0, b0, c0, d0}
	for i := 0; i < 4; i += 1 {
		w := words[i]
		out[i*4+0] = cast(u8)(w >> 0)
		out[i*4+1] = cast(u8)(w >> 8)
		out[i*4+2] = cast(u8)(w >> 16)
		out[i*4+3] = cast(u8)(w >> 24)
	}
	hex := make([]u8, 32)
	digits := "0123456789abcdef"
	for i := 0; i < 16; i += 1 {
		hex[i*2+0] = digits[cast(int)(out[i] >> 4)]
		hex[i*2+1] = digits[cast(int)(out[i] & 0x0f)]
	}
	return string(hex)
}
