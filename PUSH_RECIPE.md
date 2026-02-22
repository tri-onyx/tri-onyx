cd /home/sondre/Repositories/TriOnyx
git init
git add -A
git status  # verify no .env, .betterbeads/, or secrets staged
git commit -m "feat: initial commit"
git remote add origin https://github.com/tri-onyx/tri-onyx.git
git branch -M main
git push -u origin main
