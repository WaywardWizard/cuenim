common: w: 0
common: x: 0
common: y: 0
common: z: 0
app: {
	nested: flag: true
	n0:      -2.23
	n1:      4200
	n2:      2.32423e7
	n3:      2.32423e-7
	n4:      -2.32423e-7
	n5:      2.32423E7
	n6:      2.32423E-7
	n7:      -0.3242E33 // big number breaks Number.MAX_SAFE_INTEGER
	n8:      0.23
	n9:      -0.23
	string:  "foo"
	number:  42
	fnumber: 3.14
}
compiled: testString: "hello world"