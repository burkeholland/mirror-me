package main

// App preferences do not interrupt a live receiver session.
func configAffectsReceiver(a, b Config) bool {
	return a.DeviceName != b.DeviceName ||
		a.Resolution != b.Resolution ||
		a.MaxFPS != b.MaxFPS ||
		a.AudioEnabled != b.AudioEnabled ||
		a.HardwareDecode != b.HardwareDecode ||
		a.H265 != b.H265 ||
		a.PreferNewestConnection != b.PreferNewestConnection ||
		a.IdleTimeoutSeconds != b.IdleTimeoutSeconds ||
		a.RequirePin != b.RequirePin ||
		(a.RequirePin && a.PinCode != b.PinCode)
}
