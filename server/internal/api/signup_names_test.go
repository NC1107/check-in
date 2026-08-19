package api

import "testing"

// Nothing checked that signup stored first and last name the right way round: transposing
// them at the CreateUser call site left the whole api suite green. Four adjacent string
// parameters were exactly the shape that lets a transposition through the compiler, which
// is why CreateUser now takes db.NewUser - but the struct only makes the mistake visible,
// so this is what makes it fail.
func TestSignupStoresFirstAndLastNameSeparately(t *testing.T) {
	h := newHarness(t)

	phone := h.nextPhone()
	res := h.post("/api/auth/signup", "", map[string]any{
		"phone":     phone,
		"firstName": "Ada",
		"lastName":  "Lovelace",
		"birthday":  "1990-04-01",
		"password":  testPassword,
	})
	res.expect(200)

	var got struct {
		User struct {
			FirstName string `json:"firstName"`
			LastName  string `json:"lastName"`
			Name      string `json:"name"`
		} `json:"user"`
	}
	res.decode(&got)

	if got.User.FirstName != "Ada" {
		t.Errorf("firstName = %q, want \"Ada\"", got.User.FirstName)
	}
	if got.User.LastName != "Lovelace" {
		t.Errorf("lastName = %q, want \"Lovelace\"", got.User.LastName)
	}
	// The display name is built from the two, so a transposition shows up here as well.
	if got.User.Name != "Ada Lovelace" {
		t.Errorf("name = %q, want \"Ada Lovelace\"", got.User.Name)
	}
}
