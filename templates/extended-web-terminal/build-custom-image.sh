oc new-build --name web-terminal-openshell --strategy docker --binary --context-dir . -n wksp-user1
oc start-build web-terminal-openshell --from-dir . --follow --no-cache -n wksp-user1
