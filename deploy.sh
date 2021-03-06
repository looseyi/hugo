#!/bin/sh

# rm old post
# git rm --cached public

# # add git submodule to public path
# git submodule add -f -b master git@github.com:looseyi/looseyi.github.io.git public

# If a command fails then the deploy stops
set -e

printf "\033[0;32mDeploying updates to GitHub...\033[0m\n"

# Build the project.
hugo --ignoreCache --verbose # if using a theme, replace with `hugo -t <YOURTHEME>`

# Go To Public folder
cd public

# Add changes to git.
git add .

# Commit changes.
msg="rebuilding site $(date)"
if [ -n "$*" ]; then
	msg="$*"
fi
git commit -m "$msg"

# Push source and build repos.
git push origin master -f