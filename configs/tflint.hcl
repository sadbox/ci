# The default tflint configuration lint.yml uses when the caller has none
# (.tflint.hcl in the repository root, or the tflint-config input). A
# caller's own file replaces this one entirely.
#
# Only the terraform ruleset bundled in tflint, so nothing is downloaded.
# Its warnings fail the job, as tflint's own default.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
