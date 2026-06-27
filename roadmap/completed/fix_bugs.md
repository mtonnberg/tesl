# Context

A user with tesl installed via nixflake (latest version) and version 0.6.22 of the vscodium extension


# Bugs


- Following keywords break the scroll minimap (the text becomes large in the minimap):
    - type
    - entity
    - database
    - fn
    - auth
    - codec
    - handler
    - could be more
- Missing vscodium profile for debug/test (should be an option during "tesl init")
- Cannot start single unittest via codelens (run all tests in file works)
    - Here is the raw output: "/home/mikael/.nix-profile/bin/tesl" --test-name "title length boundary" "/home/mikael/Documents/repos/tesl-test01/test01/app.tesl" > "/tmp/tesl-test-1782483323831.rkt" && "/nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/bin/raco" test "/tmp/tesl-test-1782483323831.rkt"; rm -f "/tmp/tesl-test-1782483323831.rkt"
(base) mikael@mikael-ThinkPad-X1-Carbon-Gen-9-CC:~/Documents/repos/tesl-test01/test01$ "/home/mikael/.nix-profile/bin/tesl" --test-name "title length boundary" "/home/mikael/Documents/repos/tesl-test01/test01/app.tesl" > "/tmp/tesl-test-1782483323831.rkt" && "/nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/bin/raco" test "/tmp/tesl-test-1782483323831.rkt"; rm -f "/tmp/tesl-test-1782483323831.rkt"
unknown command: --test-name  (try: tesl help)
- Test debug(after I manually copied the launch.json from the repo) fails with:
    - "[tesl-debug] racket:        /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/bin/racket [tesl-debug] dap-server:    NOT FOUND [tesl-debug] compiler:      /home/mikael/.nix-profile/bin/tesl [tesl-debug] PLTCOLLECTS:   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/collects:/nix/store/msj5vg9l2lyzb5vkqkzxixlll7a9ji8v-tesl-racket-collections-0.1.0/share/tesl-collections:/home/mikael/Documents/repos/tesl-test01/test01/.tesl-collections [tesl-debug] TESL_REPO_ROOT:/home/mikael/Documents/repos/tesl-test01/test01"
- In the following codeblock the "w" in the second with does not have the "keyword" color (but rest of the word has it) 
    ```tesl
    with database AppDatabase {
    with capabilities [appWebService] {
      seedExampleData()
    }
    serve AppServer on port with capabilities [appWebService]
  }
  ```
- same for the t in telemetry in this block:
```tesl
handler getTodo(requestUser: User ::: Authenticated requestUser, todoId: String ::: TodoId todoId)
  -> Todo ? FromDb (Id == todoId)
  requires [appDbRead] =
  telemetry "todo.get" { user.id = requestUser.id }
  let existing = selectOne todo from Todo where todo.id == todoId
  case existing of
    Nothing ->
      fail 404 "Todo not found"
``` 
- the word "let" in the codeblock below miss the keyword color all together, the i in "initTelemetry" also misses the right color:
```tesl
main with capabilities [appWebService] {
  initTelemetry service "test01" endpoint "in-memory" console True
  let port = envInt "PORT" defaultPort
  with database AppDatabase {
    with capabilities [appWebService] {
      seedExampleData()
    }
    serve AppServer on port with capabilities [appWebService]
  }
}
```
- the main function is not marked as a keyword at all (just yellow like a function)
- F2 renaming works in some cases
  - does not rename inside proofs (after the :::)
  - if you f2 when the caret is after the m on "somerecord.id" to "somerecord2.id" it replaces all somerecord with somerecord.id
    - Solution: only enter the name of the actual thing we are renaming (somerecord), if the user removes .id themselves it works
  - Renaming types seem not to work at all
  - Renaming popup shows even when trying to rename types from standard lib (like String)
  - Renaming popup shows even when trying to rename keywords (like handler, or requires)
  - Renaming popup shows even when trying to rename the ::: operator
- type tool tip:
  - Seems to work for simpler cases
  - when hovering on the property part, lik "aRecord.aProperty" the type says "Unit" even if the type of aProperty is something else
- tesl run failed after "tesl init" with managed db:
```sh
tesl run app.tesl
[tesl] Starting...
tcp-connect: connection failed
  hostname: localhost
  port number: 5432
  system error: Connection refused; errno=111
  context...:
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/pkgs/db-lib/db/private/postgresql/main.rkt:64:6
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/pkgs/db-lib/db/private/postgresql/main.rkt:13:0: postgresql-connect
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/collects/racket/contract/private/arrow-val-first.rkt:587:3
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/collects/racket/contract/private/arrow-higher-order.rkt:375:33
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/pkgs/db-lib/db/private/generic/connect-util.rkt:287:4: lease* method in connection-pool-manager%
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/pkgs/db-lib/db/private/generic/connect-util.rkt:17:10
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/pkgs/db-lib/db/private/generic/connect-util.rkt:15:2: wrapped-proc
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/pkgs/db-lib/db/private/generic/connect-util.rkt:42:7
```
- I changed one of the default test to fail and then ran "tesl test app.tesl" and got this output, while it failed the feedback is horrendous:
```sh
$> tesl test app.tesl 
raco test: (submod (file "app.rkt") test)
--------------------
todo id shape
FAILURE
name:       check-true
location:   app.rkt:178:2
params:     '(#f)
--------------------
1/2 test failures

```
- Not strictly a bug but no option on how complex the example should be during "tesl init", only one example is ok but it is missing queues, workers, ssr, mutation testing, property based testing, api-testing. Keep this example as mini and add a "full" with all the bells and whistles.
-  "tesl build" failed after "test init" (sudo fails aswell since tesl is installed via nix on the user's profile and not roots, which is correct in itself)
```sh
$> tesl build
tesl build: staging context at /tmp/tmp.dDA3ht8KLp (variant=all-in-one, port=8086)
tesl build: staged Dockerfile (all-in-one) + app.rkt + collections
tesl build: building image 'test01' ...
ERROR: permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get "http://%2Fvar%2Frun%2Fdocker.sock/_ping": dial unix /var/run/docker.sock: connect: permission denied
tesl build: docker build failed
```
- This incorrect endpoint (part of the api-block) (it lacks a capture statement for :string) does not generate a compile error but fails on "tesl run"
```tesl
  get "/ping/:string"
      -> String
```
- This incorrect endpoint (part of the api-block) does not generate a compile error but fails on "tesl run"
```tesl
  get "/ping/:s"
    capture s: String via stringCodec
      -> String
```
- Same with this
```tesl
  get "/ping/:s"
    capture s: String using stringCodec
      -> String
```
- "tesl run" failed after "tesl init"
```sh
$> tesl run app.tesl
[tesl] Starting...
tcp-connect: connection failed
  hostname: localhost
  port number: 5432
  system error: Connection refused; errno=111
  context...:
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/pkgs/db-lib/db/private/postgresql/main.rkt:64:6
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/pkgs/db-lib/db/private/postgresql/main.rkt:13:0: postgresql-connect
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/collects/racket/contract/private/arrow-val-first.rkt:587:3
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/collects/racket/contract/private/arrow-higher-order.rkt:375:33
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/pkgs/db-lib/db/private/generic/connect-util.rkt:287:4: lease* method in connection-pool-manager%
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/pkgs/db-lib/db/private/generic/connect-util.rkt:17:10
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/pkgs/db-lib/db/private/generic/connect-util.rkt:15:2: wrapped-proc
   /nix/store/cb4al1b516z5326ybckfsm3ir4dqpwaz-racket-9.2/share/racket/pkgs/db-lib/db/private/generic/connect-util.rkt:42:7
```


## Things that worked

- The inferred type is shown correctly inline
- the "tesl init" command generated a starting point