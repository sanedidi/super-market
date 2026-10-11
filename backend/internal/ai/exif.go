package ai

import (
	"encoding/binary"
	"image"
)

// Поворот фото с телефона. Камера часто пишет JPEG «боком» и ставит в EXIF
// пометку Orientation — «показывать повернув». Браузер её учитывает, а
// image.Decode в Go — нет: без поворота Gemini получал, например, пачку масла
// на боку и возвращал её вертикальной.

// jpegOrientation — EXIF Orientation (1–8) из JPEG; 1, если её нет или файл не JPEG.
func jpegOrientation(raw []byte) int {
	if len(raw) < 4 || raw[0] != 0xFF || raw[1] != 0xD8 {
		return 1
	}
	p := 2
	for p+4 <= len(raw) {
		if raw[p] != 0xFF {
			return 1
		}
		marker := raw[p+1]
		if marker == 0xFF { // заполнитель
			p++
			continue
		}
		if marker == 0xD9 || marker == 0xDA { // конец файла или начало данных — EXIF уже не будет
			return 1
		}
		if marker >= 0xD0 && marker <= 0xD7 || marker == 0x01 { // маркеры без длины
			p += 2
			continue
		}
		n := int(binary.BigEndian.Uint16(raw[p+2 : p+4]))
		if n < 2 || p+2+n > len(raw) {
			return 1
		}
		seg := raw[p+4 : p+2+n]
		if marker == 0xE1 && len(seg) > 6 && string(seg[:6]) == "Exif\x00\x00" {
			if o := tiffOrientation(seg[6:]); o >= 1 && o <= 8 {
				return o
			}
			return 1
		}
		p += 2 + n
	}
	return 1
}

// tiffOrientation — тег 0x0112 из IFD0 заголовка TIFF; 0, если его нет.
func tiffOrientation(t []byte) int {
	if len(t) < 8 {
		return 0
	}
	var bo binary.ByteOrder
	switch string(t[:2]) {
	case "II":
		bo = binary.LittleEndian
	case "MM":
		bo = binary.BigEndian
	default:
		return 0
	}
	if bo.Uint16(t[2:4]) != 42 {
		return 0
	}
	ifd := int(bo.Uint32(t[4:8]))
	if ifd < 8 || ifd+2 > len(t) {
		return 0
	}
	count := int(bo.Uint16(t[ifd : ifd+2]))
	for i := 0; i < count; i++ {
		e := ifd + 2 + i*12
		if e+12 > len(t) {
			return 0
		}
		if bo.Uint16(t[e:e+2]) == 0x0112 && bo.Uint16(t[e+2:e+4]) == 3 { // SHORT
			return int(bo.Uint16(t[e+8 : e+10]))
		}
	}
	return 0
}

// orient — картинка так, как её показывает браузер по EXIF Orientation.
func orient(src *image.RGBA, o int) *image.RGBA {
	if o < 2 || o > 8 {
		return src
	}
	w, h := src.Bounds().Dx(), src.Bounds().Dy()
	dw, dh := w, h
	if o >= 5 { // 5–8 меняют стороны местами
		dw, dh = h, w
	}
	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			var dx, dy int
			switch o {
			case 2: // зеркально по горизонтали
				dx, dy = w-1-x, y
			case 3: // 180°
				dx, dy = w-1-x, h-1-y
			case 4: // зеркально по вертикали
				dx, dy = x, h-1-y
			case 5: // транспонирование
				dx, dy = y, x
			case 6: // 90° по часовой
				dx, dy = h-1-y, x
			case 7: // поперечное транспонирование
				dx, dy = h-1-y, w-1-x
			case 8: // 90° против часовой
				dx, dy = y, w-1-x
			}
			s := src.PixOffset(x, y)
			d := dst.PixOffset(dx, dy)
			copy(dst.Pix[d:d+4], src.Pix[s:s+4])
		}
	}
	return dst
}
