package teslrt

import "testing"

func TestRowGenerationMarkerBounds(t *testing.T) {
	for _, generation := range []int{1, 2, 32766, 32767} {
		marker, err := pgRowGenerationMarker(generation)
		if err != nil || int(marker) != generation {
			t.Fatalf("generation %d changed: %d, %v", generation, marker, err)
		}
	}
	// 65537 would wrap to the valid baseline marker 1 without the range check.
	for _, generation := range []int{-65535, -1, 0, 32768, 65536, 65537} {
		if marker, err := pgRowGenerationMarker(generation); err == nil || marker != 0 {
			t.Fatalf("invalid generation %d became a stored marker: %d, %v", generation, marker, err)
		}
	}
}
