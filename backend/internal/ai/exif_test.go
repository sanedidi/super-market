package ai

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/jpeg"
	"testing"
)

// withOrientation — JPEG с EXIF Orientation o (APP1 сразу после SOI).
func withOrientation(t *testing.T, img image.Image, o int, bo binary.ByteOrder) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 95}); err != nil {
		t.Fatal(err)
	}
	raw := buf.Bytes()
	tiff := make([]byte, 8+2+12+4)
	if bo == binary.LittleEndian {
		copy(tiff, "II")
	} else {
		copy(tiff, "MM")
	}
	bo.PutUint16(tiff[2:], 42)
	bo.PutUint32(tiff[4:], 8)
	bo.PutUint16(tiff[8:], 1)
	bo.PutUint16(tiff[10:], 0x0112)
	bo.PutUint16(tiff[12:], 3)
	bo.PutUint32(tiff[14:], 1)
	bo.PutUint16(tiff[18:], uint16(o))
	seg := append([]byte("Exif\x00\x00"), tiff...)
	app1 := []byte{0xFF, 0xE1, 0, 0}
	binary.BigEndian.PutUint16(app1[2:], uint16(len(seg)+2))
	out := append([]byte{}, raw[:2]...)
	out = append(out, app1...)
	out = append(out, seg...)
	return append(out, raw[2:]...)
}

func TestJPEGOrientation(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 40, 20))
	for _, bo := range []binary.ByteOrder{binary.LittleEndian, binary.BigEndian} {
		for o := 1; o <= 8; o++ {
			if got := jpegOrientation(withOrientation(t, img, o, bo)); got != o {
				t.Fatalf("%v o=%d: got %d", bo, o, got)
			}
		}
	}
	var plain bytes.Buffer
	_ = jpeg.Encode(&plain, img, nil)
	if got := jpegOrientation(plain.Bytes()); got != 1 {
		t.Fatalf("без EXIF: %d", got)
	}
	if got := jpegOrientation([]byte("not a jpeg")); got != 1 {
		t.Fatalf("не JPEG: %d", got)
	}
	if got := jpegOrientation([]byte{0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF}); got != 1 {
		t.Fatalf("битый: %d", got)
	}
}

func TestOrient(t *testing.T) {
	// 3×2, красная точка в левом верхнем углу.
	src := image.NewRGBA(image.Rect(0, 0, 3, 2))
	red := color.RGBA{255, 0, 0, 255}
	src.Set(0, 0, red)
	cases := []struct {
		o, w, h, x, y int
	}{
		{1, 3, 2, 0, 0}, {2, 3, 2, 2, 0}, {3, 3, 2, 2, 1}, {4, 3, 2, 0, 1},
		{5, 2, 3, 0, 0}, {6, 2, 3, 1, 0}, {7, 2, 3, 1, 2}, {8, 2, 3, 0, 2},
	}
	for _, c := range cases {
		out := orient(src, c.o)
		if out.Bounds().Dx() != c.w || out.Bounds().Dy() != c.h {
			t.Fatalf("o=%d: размер %v", c.o, out.Bounds())
		}
		if out.RGBAAt(c.x, c.y) != red {
			t.Fatalf("o=%d: точка не в (%d,%d)", c.o, c.x, c.y)
		}
	}
}

// Фото «боком» с пометкой «повернуть на 90° по часовой» уходит в Gemini уже повёрнутым.
func TestShrinkForModelAppliesOrientation(t *testing.T) {
	src := image.NewRGBA(image.Rect(0, 0, 200, 100)) // лежит горизонтально в пикселях
	for y := 0; y < 100; y++ {
		for x := 0; x < 200; x++ {
			src.Set(x, y, color.RGBA{200, 200, 200, 255})
		}
	}
	in, err := shrinkForModel(withOrientation(t, src, 6, binary.LittleEndian), "image/jpeg")
	if err != nil {
		t.Fatal(err)
	}
	got, _, err := image.Decode(bytes.NewReader(in.Data))
	if err != nil {
		t.Fatal(err)
	}
	if b := got.Bounds(); b.Dx() != 100 || b.Dy() != 200 {
		t.Fatalf("ждали 100×200, получили %v", b)
	}
	// Без пометки маленький JPEG уходит как есть.
	var plain bytes.Buffer
	_ = jpeg.Encode(&plain, src, nil)
	in, err = shrinkForModel(plain.Bytes(), "image/jpeg")
	if err != nil || !bytes.Equal(in.Data, plain.Bytes()) {
		t.Fatalf("без EXIF фото должно уйти как есть: %v", err)
	}
}
