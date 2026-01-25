# Update workflow files
[script("fish")]
@update-actions:
    echo "Updating GitHub Actions workflows..."
    pushd .github/workflows > /dev/null
    cue export --out yaml -e 'workflows."generate-publish"' > generate-publish.yaml
    popd > /dev/null