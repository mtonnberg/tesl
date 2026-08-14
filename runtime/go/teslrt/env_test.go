package teslrt

import "testing"

func TestEnvReads(t *testing.T) {
	t.Setenv("TESL_PROBE_SET", "hello")
	t.Setenv("TESL_PROBE_EMPTY", "")
	t.Setenv("TESL_PROBE_INT", "41")

	if got := EnvMaybe("TESL_PROBE_SET"); got.Tag != MaybeSomething || got.SomethingValue != "hello" {
		t.Errorf("env of a set variable = %+v", got)
	}
	// An EMPTY variable is UNSET, as it is on Racket (empty-string->false).
	if got := EnvMaybe("TESL_PROBE_EMPTY"); got.Tag != MaybeNothing {
		t.Errorf("env of an empty variable = %+v", got)
	}
	if got := EnvMaybe("TESL_PROBE_MISSING"); got.Tag != MaybeNothing {
		t.Errorf("env of a missing variable = %+v", got)
	}
	if got := EnvString("TESL_PROBE_EMPTY", "fallback"); got != "fallback" {
		t.Errorf("envString of an empty variable = %q", got)
	}
	if got := EnvString("TESL_PROBE_SET", "fallback"); got != "hello" {
		t.Errorf("envString = %q", got)
	}
	if got := EnvInt("TESL_PROBE_INT", FromInt64(7)); got.String() != "41" {
		t.Errorf("envInt = %s", got.String())
	}
	if got := EnvInt("TESL_PROBE_MISSING", FromInt64(7)); got.String() != "7" {
		t.Errorf("envInt fallback = %s", got.String())
	}
	if got := RequireEnv("TESL_PROBE_SET"); got != "hello" {
		t.Errorf("requireEnv = %q", got)
	}
}

// A set-but-unparseable value must not become the fallback: that would make a typo'd
// setting look deliberate.
func TestEnvIntTrapsOnGarbage(t *testing.T) {
	t.Setenv("TESL_PROBE_BAD", "12x")
	defer func() {
		if recover() == nil {
			t.Fatal("expected a trap on an unparseable integer")
		}
	}()
	EnvInt("TESL_PROBE_BAD", FromInt64(7))
}

func TestRequireEnvTrapsWhenUnset(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected a trap on an unset variable")
		}
	}()
	RequireEnv("TESL_PROBE_DEFINITELY_MISSING")
}
