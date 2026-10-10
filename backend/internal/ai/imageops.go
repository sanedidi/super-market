package ai

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	"image/draw"
	_ "image/gif" // декодеры: Gemini присылает PNG или JPEG, магазин грузит любое
	"image/jpeg"
	_ "image/png"
)

// Подготовка фото для Gemini и готового фото для каталога — без внешних библиотек.

// photoInputSide — фото больше этого уменьшается перед отправкой в Gemini:
// так меньше трафика и входных токенов, а качества хватает.
const photoInputSide = 1600

// shrinkForModel — JPEG не больше photoInputSide по большей стороне.
// Маленькие JPEG/PNG уходят как есть.
func shrinkForModel(raw []byte, mime string) (Image, error) {
	src, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return Image{}, errors.New("не удалось прочитать фото")
	}
	b := src.Bounds()
	if b.Dx() <= photoInputSide && b.Dy() <= photoInputSide && (mime == "image/jpeg" || mime == "image/png") {
		return Image{MIME: mime, Data: raw}, nil
	}
	nw, nh := fitIn(b.Dx(), b.Dy(), photoInputSide)
	rgba := flatten(src, color.RGBA{255, 255, 255, 255})
	out := resize(rgba, nw, nh)
	data, err := encodeJPEG(out, 90)
	return Image{MIME: "image/jpeg", Data: data}, err
}

// squarePhoto — готовое фото каталога: квадрат size×size на фоне bg, товар
// вписан целиком по центру, JPEG.
func squarePhoto(raw []byte, size int, bg color.RGBA) ([]byte, error) {
	src, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, errors.New("Gemini прислал фото, которое не удалось прочитать")
	}
	b := src.Bounds()
	if b.Dx() == 0 || b.Dy() == 0 {
		return nil, errors.New("Gemini прислал пустое фото")
	}
	rgba := flatten(src, bg)
	nw, nh := fitIn(b.Dx(), b.Dy(), size)
	scaled := resize(rgba, nw, nh)
	canvas := image.NewRGBA(image.Rect(0, 0, size, size))
	draw.Draw(canvas, canvas.Bounds(), &image.Uniform{C: bg}, image.Point{}, draw.Src)
	off := image.Pt((size-nw)/2, (size-nh)/2)
	draw.Draw(canvas, scaled.Bounds().Add(off), scaled, image.Point{}, draw.Src)
	return encodeJPEG(canvas, 90)
}

// fitIn — размер, вписанный в квадрат side с сохранением пропорций.
func fitIn(w, h, side int) (int, int) {
	if w >= h {
		return side, max(1, h*side/w)
	}
	return max(1, w*side/h), side
}

// flatten — картинка в RGBA с фоном bg вместо прозрачного.
func flatten(src image.Image, bg color.RGBA) *image.RGBA {
	b := src.Bounds()
	out := image.NewRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	draw.Draw(out, out.Bounds(), &image.Uniform{C: bg}, image.Point{}, draw.Src)
	draw.Draw(out, out.Bounds(), src, b.Min, draw.Over)
	return out
}

func encodeJPEG(img image.Image, q int) ([]byte, error) {
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: q}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// resize — уменьшение усреднением (без «лесенки»), увеличение — билинейно.
func resize(src *image.RGBA, nw, nh int) *image.RGBA {
	w, h := src.Bounds().Dx(), src.Bounds().Dy()
	if nw == w && nh == h {
		return src
	}
	if nw <= w && nh <= h {
		return boxResize(src, nw, nh)
	}
	return bilinear(src, nw, nh)
}

func boxResize(src *image.RGBA, nw, nh int) *image.RGBA {
	w, h := src.Bounds().Dx(), src.Bounds().Dy()
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	for y := 0; y < nh; y++ {
		y0, y1 := y*h/nh, (y+1)*h/nh
		if y1 <= y0 {
			y1 = y0 + 1
		}
		for x := 0; x < nw; x++ {
			x0, x1 := x*w/nw, (x+1)*w/nw
			if x1 <= x0 {
				x1 = x0 + 1
			}
			var r, g, bl, a, n uint64
			for yy := y0; yy < y1; yy++ {
				off := yy*src.Stride + x0*4
				for xx := x0; xx < x1; xx++ {
					p := src.Pix[off : off+4 : off+4]
					r += uint64(p[0])
					g += uint64(p[1])
					bl += uint64(p[2])
					a += uint64(p[3])
					n++
					off += 4
				}
			}
			d := dst.PixOffset(x, y)
			dst.Pix[d] = uint8(r / n)
			dst.Pix[d+1] = uint8(g / n)
			dst.Pix[d+2] = uint8(bl / n)
			dst.Pix[d+3] = uint8(a / n)
		}
	}
	return dst
}

func bilinear(src *image.RGBA, nw, nh int) *image.RGBA {
	w, h := src.Bounds().Dx(), src.Bounds().Dy()
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	for y := 0; y < nh; y++ {
		fy := (float64(y)+0.5)*float64(h)/float64(nh) - 0.5
		y0 := int(fy)
		if fy < 0 {
			y0, fy = 0, 0
		}
		y1 := min(y0+1, h-1)
		dy := fy - float64(y0)
		for x := 0; x < nw; x++ {
			fx := (float64(x)+0.5)*float64(w)/float64(nw) - 0.5
			x0 := int(fx)
			if fx < 0 {
				x0, fx = 0, 0
			}
			x1 := min(x0+1, w-1)
			dx := fx - float64(x0)
			d := dst.PixOffset(x, y)
			for c := 0; c < 4; c++ {
				p00 := float64(src.Pix[src.PixOffset(x0, y0)+c])
				p10 := float64(src.Pix[src.PixOffset(x1, y0)+c])
				p01 := float64(src.Pix[src.PixOffset(x0, y1)+c])
				p11 := float64(src.Pix[src.PixOffset(x1, y1)+c])
				v := p00*(1-dx)*(1-dy) + p10*dx*(1-dy) + p01*(1-dx)*dy + p11*dx*dy
				dst.Pix[d+c] = uint8(v + 0.5)
			}
		}
	}
	return dst
}
