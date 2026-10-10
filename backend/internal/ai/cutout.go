package ai

import (
	"bytes"
	"errors"
	"image"
	"image/png"
	"math"
	"sort"
)

// Прозрачный фон («ИИ для фото» → Фон: Прозрачный). Картинки с альфа-каналом
// Gemini не рисует, поэтому он кладёт товар на ровный пурпурный фон (#FF00FF —
// такого цвета почти не бывает на упаковках), а здесь фон вырезается: от краёв
// картинки заливкой убираются пиксели цвета фона, на границе — плавный переход
// с очисткой оттенка фона. Товар обрезается по краям, вписывается в квадрат и
// сохраняется в PNG.

const (
	// keyNear — до этого расстояния до цвета фона пиксель полностью прозрачный,
	// keyFar — дальше уже товар; между ними — полупрозрачный край.
	keyNear = 70.0
	keyFar  = 150.0
	// cutoutFill — какую долю квадрата занимает товар.
	cutoutFill = 0.88
)

// transparentPhoto — PNG size×size: товар без фона по центру. Если ровного фона
// у краёв нет (Gemini его не сделал), фон не трогается — картинка вписывается как есть.
func transparentPhoto(raw []byte, size int) ([]byte, error) {
	src, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, errors.New("Gemini прислал фото, которое не удалось прочитать")
	}
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	if w == 0 || h == 0 {
		return nil, errors.New("Gemini прислал пустое фото")
	}
	rgba := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			rgba.Set(x, y, src.At(b.Min.X+x, b.Min.Y+y))
		}
	}
	if key, ok := borderKey(rgba); ok {
		cutBackground(rgba, key)
	}
	box, ok := opaqueBounds(rgba)
	if !ok {
		// Вырезалось всё — значит, «фоном» была сама картинка; оставляем как есть.
		box = rgba.Bounds()
		for i := 3; i < len(rgba.Pix); i += 4 {
			rgba.Pix[i] = 255
		}
	}
	crop := image.NewRGBA(image.Rect(0, 0, box.Dx(), box.Dy()))
	for y := 0; y < box.Dy(); y++ {
		copy(crop.Pix[y*crop.Stride:y*crop.Stride+box.Dx()*4], rgba.Pix[(box.Min.Y+y)*rgba.Stride+box.Min.X*4:])
	}
	side := int(float64(size) * cutoutFill)
	nw, nh := fitIn(box.Dx(), box.Dy(), side)
	scaled := resize(premultiplied(crop), nw, nh)
	unpremultiply(scaled)
	canvas := image.NewNRGBA(image.Rect(0, 0, size, size))
	ox, oy := (size-nw)/2, (size-nh)/2
	for y := 0; y < nh; y++ {
		copy(canvas.Pix[(oy+y)*canvas.Stride+ox*4:(oy+y)*canvas.Stride+(ox+nw)*4], scaled.Pix[y*scaled.Stride:y*scaled.Stride+nw*4])
	}
	var buf bytes.Buffer
	enc := png.Encoder{CompressionLevel: png.BestCompression}
	if err := enc.Encode(&buf, canvas); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

type rgb struct{ r, g, b float64 }

func (c rgb) dist(r, g, b uint8) float64 {
	dr, dg, db := float64(r)-c.r, float64(g)-c.g, float64(b)-c.b
	return math.Sqrt(dr*dr + dg*dg + db*db)
}

// borderKey — цвет фона по краям: медиана пикселей рамки, если рамка ровная
// (не меньше 70% пикселей близки к медиане).
func borderKey(img *image.RGBA) (rgb, bool) {
	w, h := img.Bounds().Dx(), img.Bounds().Dy()
	var rs, gs, bs []float64
	add := func(x, y int) {
		p := img.Pix[img.PixOffset(x, y):]
		rs, gs, bs = append(rs, float64(p[0])), append(gs, float64(p[1])), append(bs, float64(p[2]))
	}
	for x := 0; x < w; x++ {
		add(x, 0)
		add(x, h-1)
	}
	for y := 1; y < h-1; y++ {
		add(0, y)
		add(w-1, y)
	}
	med := func(v []float64) float64 {
		s := append([]float64(nil), v...)
		sort.Float64s(s)
		return s[len(s)/2]
	}
	key := rgb{med(rs), med(gs), med(bs)}
	near := 0
	for i := range rs {
		if key.dist(uint8(rs[i]), uint8(gs[i]), uint8(bs[i])) < keyNear {
			near++
		}
	}
	return key, near*10 >= len(rs)*7
}

// cutBackground — заливка от краёв: пиксели цвета фона прозрачные, на границе —
// полупрозрачные с очищенным от фона цветом.
func cutBackground(img *image.RGBA, key rgb) {
	w, h := img.Bounds().Dx(), img.Bounds().Dy()
	seen := make([]bool, w*h)
	queue := make([]int, 0, 2*(w+h))
	push := func(x, y int) {
		i := y*w + x
		if seen[i] {
			return
		}
		p := img.Pix[i*4:]
		if key.dist(p[0], p[1], p[2]) >= keyFar {
			return
		}
		seen[i] = true
		queue = append(queue, i)
	}
	for x := 0; x < w; x++ {
		push(x, 0)
		push(x, h-1)
	}
	for y := 0; y < h; y++ {
		push(0, y)
		push(w-1, y)
	}
	for len(queue) > 0 {
		i := queue[len(queue)-1]
		queue = queue[:len(queue)-1]
		x, y := i%w, i/w
		p := img.Pix[i*4 : i*4+4 : i*4+4]
		d := key.dist(p[0], p[1], p[2])
		if d <= keyNear {
			p[0], p[1], p[2], p[3] = 0, 0, 0, 0
		} else {
			// Край: прозрачность по близости к фону, цвет — без примеси фона.
			a := (d - keyNear) / (keyFar - keyNear)
			unmix := func(c uint8, k float64) uint8 {
				v := (float64(c) - (1-a)*k) / a
				return uint8(math.Max(0, math.Min(255, v)))
			}
			p[0], p[1], p[2] = unmix(p[0], key.r), unmix(p[1], key.g), unmix(p[2], key.b)
			p[3] = uint8(a * 255)
			// Дальше края не идём: за ним товар.
			continue
		}
		if x > 0 {
			push(x-1, y)
		}
		if x < w-1 {
			push(x+1, y)
		}
		if y > 0 {
			push(x, y-1)
		}
		if y < h-1 {
			push(x, y+1)
		}
	}
}

// opaqueBounds — рамка непрозрачной части; ok=false — картинка вся прозрачная.
func opaqueBounds(img *image.RGBA) (image.Rectangle, bool) {
	w, h := img.Bounds().Dx(), img.Bounds().Dy()
	minX, minY, maxX, maxY := w, h, -1, -1
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if img.Pix[y*img.Stride+x*4+3] > 8 {
				minX, minY = min(minX, x), min(minY, y)
				maxX, maxY = max(maxX, x), max(maxY, y)
			}
		}
	}
	if maxX < 0 {
		return image.Rectangle{}, false
	}
	return image.Rect(minX, minY, maxX+1, maxY+1), true
}

// premultiplied — цвет, умноженный на прозрачность: так при уменьшении на
// краях не появляется тёмная или цветная кайма.
func premultiplied(img *image.RGBA) *image.RGBA {
	out := image.NewRGBA(img.Bounds())
	for i := 0; i < len(img.Pix); i += 4 {
		a := uint16(img.Pix[i+3])
		out.Pix[i] = uint8(uint16(img.Pix[i]) * a / 255)
		out.Pix[i+1] = uint8(uint16(img.Pix[i+1]) * a / 255)
		out.Pix[i+2] = uint8(uint16(img.Pix[i+2]) * a / 255)
		out.Pix[i+3] = uint8(a)
	}
	return out
}

// unpremultiply — обратно к обычному цвету (для PNG c NRGBA).
func unpremultiply(img *image.RGBA) {
	for i := 0; i < len(img.Pix); i += 4 {
		a := uint16(img.Pix[i+3])
		if a == 0 {
			img.Pix[i], img.Pix[i+1], img.Pix[i+2] = 0, 0, 0
			continue
		}
		img.Pix[i] = uint8(min(255, uint16(img.Pix[i])*255/a))
		img.Pix[i+1] = uint8(min(255, uint16(img.Pix[i+1])*255/a))
		img.Pix[i+2] = uint8(min(255, uint16(img.Pix[i+2])*255/a))
	}
}
