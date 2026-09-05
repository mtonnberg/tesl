module Guide exposing (Step, chapters, steps, exerciseIds, findByKey, stepExample, repairFor, chapterSteps, stepTitle, nextJourneyStep, testCommand)

{-| One catalog owns step identity, order, chapters, examples and suggested edits.
Browser storage only persists opaque numeric IDs; the guide decides which IDs count.
-}
type alias Repair = { before : String, after : String, why : String }
type alias Step = { id : Int, chapter : Int, example : Int, key : String, title : String, repair : Repair, testCommand : Maybe String }

chapters : List (Int, String)
chapters = [(0, "Your first API"), (2, "Rules that travel with your code"), (5, "Money and measurements"), (7, "Testing your code"), (3, "Run it locally")]

steps : List Step
steps =
    [
    { id = 0, chapter = 0, example = 4, key = "api", title = "Your first endpoint", repair = { before = "Hello from Tesl!", after = "Hello from my API!", why = "Change the greeting returned by hello. Try your own message, or apply this example edit." }, testCommand = Nothing }
    ,
    { id = 1, chapter = 0, example = 2, key = "compiler", title = "A helpful compiler", repair = { before = "import Tesl.Prelude exposing [Int, String]", after = "import Tesl.Prelude exposing [Int, String]\nimport Tesl.String exposing [String.length]", why = "Bring String.length into scope with an import. The compiler also offers this fix in its diagnostic." }, testCommand = Nothing }
    ,
    { id = 2, chapter = 2, example = 1, key = "workspace", title = "Keep a workspace rule", repair = { before = "  invoiceLabel raw workspace", after = "  let invoice = check checkWorkspace raw workspace\n  invoiceLabel invoice workspace", why = "Check the workspace before calling invoiceLabel. The returned value carries the evidence that function requires." }, testCommand = Nothing }
    ,
    { id = 4, chapter = 2, example = 5, key = "capabilities", title = "Follow a capability", repair = { before = "  requires [dbRead Note]", after = "  requires [dbWrite Note]", why = "publishNote calls a helper that writes. Declare dbWrite Note on the caller too." }, testCommand = Nothing }
    ,
    { id = 5, chapter = 5, example = 6, key = "money", title = "Keep currencies apart", repair = { before = "  Money.add price shipping", after = "  let checked = check Money.requireSameCurrency price shipping\n  Money.add price checked", why = "Check that both amounts carry the same currency, then pass the checked amount to Money.add." }, testCommand = Nothing }
    ,
    { id = 6, chapter = 5, example = 7, key = "dimensions", title = "Check your dimensions", repair = { before = "  speed + elapsed", after = "  speed * elapsed", why = "Speed multiplied by time gives distance. Replace addition with multiplication." }, testCommand = Nothing }
    ,
    { id = 7, chapter = 7, example = 8, key = "tests", title = "Example tests", repair = { before = "# Add a test for the lower boundary here.", after = "test \"below zero becomes zero\" {\n  expect clamp -3 == 0\n}", why = "Add a concrete input and expected result. This checks the lower boundary of clamp." }, testCommand = Just "tesl test RegularTests.tesl" }
    ,
    { id = 11, chapter = 7, example = 12, key = "doctests", title = "Documentation tests", repair = { before = "# Add an example for zero here.", after = "#> double 0\n#= 0", why = "Add an input and its expected result above double. These documentation lines become another test when you run tesl test." }, testCommand = Just "tesl test DocTests.tesl" }
    ,
    { id = 8, chapter = 7, example = 9, key = "fuzz", title = "Fuzz / property tests", repair = { before = "# Add a property for clamping twice here.", after = "test \"clamping twice changes nothing\" with 100 runs {\n  property \"idempotent\" (n: Int) { clamp (clamp n) == clamp n }\n}", why = "Describe a rule that should hold across generated inputs, rather than listing every input yourself." }, testCommand = Just "tesl test PropertyTests.tesl" }
    ,
    { id = 9, chapter = 7, example = 10, key = "api-tests", title = "API tests", repair = { before = "# Add a test for an unknown route here.", after = "api-test \"unknown route returns 404\" for GreetingServer {\n  let response = get \"/missing\"\n  expect response.status == 404\n}", why = "Exercise the route through the API test harness and assert on the HTTP response." }, testCommand = Just "tesl test ApiTests.tesl" }
    ,
    { id = 10, chapter = 7, example = 11, key = "load-tests", title = "Load tests", repair = { before = "  # Add a latency budget here.", after = "  assert p95 < 500ms", why = "Add a latency budget to the existing error-rate check. This small workload runs inside the local test harness." }, testCommand = Just "tesl test LoadTests.tesl" }
    ,
    { id = 3, chapter = 3, example = 4, key = "runtime", title = "Take it with you", repair = { before = "", after = "", why = "" }, testCommand = Nothing }
    ]

find : Int -> Maybe Step
find id = List.filter (\step -> step.id == id) steps |> List.head

findByKey : String -> Maybe Step
findByKey key = List.filter (\step -> step.key == key) steps |> List.head

exerciseIds : List Int
exerciseIds = steps |> List.filter (\step -> step.repair.before /= "") |> List.map .id

stepExample : Int -> Int
stepExample id = find id |> Maybe.map .example |> Maybe.withDefault 4

repairFor : Int -> Repair
repairFor id = find id |> Maybe.map .repair |> Maybe.withDefault { before = "", after = "", why = "" }

chapterSteps : Int -> List Int
chapterSteps id =
    let chapter = find id |> Maybe.map .chapter |> Maybe.withDefault 0 in
    steps |> List.filter (\step -> step.chapter == chapter) |> List.map .id

stepTitle : Int -> String
stepTitle id = find id |> Maybe.map .title |> Maybe.withDefault ""

nextJourneyStep : Int -> Int
nextJourneyStep id =
    let index = List.indexedMap Tuple.pair steps |> List.filter (\(_, step) -> step.id == id) |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault 0 in
    List.drop (index + 1) steps |> List.head |> Maybe.map .id |> Maybe.withDefault 3

testCommand : Int -> Maybe String
testCommand id = find id |> Maybe.andThen .testCommand
