# A Request id makes a Host CLI write apply one time

A caller can give a Host CLI write a Request id: `muxify --request <uuid> <verb> …`. The Host applies the Request one time. A second send with the same id, verb and arguments prints the answer of the first send and changes nothing. The Host keeps each Request for 24 hours in a ledger, the `applied_requests` table of the state database.

The phone runs each Host CLI command over SSH and waits 8 seconds for the answer. When the answer is lost after the Host made the change, the phone shows an error, and a second tap makes the change again: `topic new` makes `fix-login-2`, `topic add-session` makes a second Session, `topic move up` moves the card two places. The phone cannot know if the first send arrived. With a Request id, it can send again safely.

## The ledger

A row has the id, the verb, the arguments, a state, and the answer: the text on standard output, the error line and the exit status. The answer is the exact text, so a second send prints the same bytes with `--json` and without it.

The arguments are the words after the verb, the caller Pane (`TMUX_PANE`) and the working directory, as JSON with sorted keys. The caller Pane is the default target, and a relative folder depends on the working directory, so the same words can mean another change. The row keeps the text, not a hash. The id with another verb or other arguments is an error with exit status 3, and the message names the id and the verb of the first send.

Each write of the ledger removes the rows that are older than 24 hours.

## Two states

A command writes the Topic records first and runs its tmux commands after that. A process can end between the two. So a row has two states.

- `started`: the records changed. `TopicStore.write` puts the row in the transaction that writes the records, so the row is there exactly when the records changed. The app never sets a Request, so it writes no row.
- `done`: the command finished and the row has its answer. The command line writes it before it prints, because a closed SSH channel can end the process at the print. If the write fails, the command prints its answer and one more error line.

A second send that finds a `started` row does what its verb's policy says. `RequestInvocation.Command.requestPolicy` is a switch with no default, so a new command does not compile until it chooses.

- `rerun`: the command gives one end state however many times it runs, so the second send runs it to its end and writes `done`. These are `topic new`, `topic add-session --name` without `--worktree`, `topic tag`, `topic note`, `topic rename`, `topic pin`, `topic unpin`, the `mark-read` and `mark-unread` verbs, `mark-all-read`, `topic choose-in-play` and `topic sort-sessions`.
- `inDoubt`: a second run could apply the change twice, such as a move of one place, a trade, a Settle or a Forget. The second send fails with exit status 4 and runs nothing. The message says that the Request changed the records and did not finish. The row stays `started`.

Two rules make `rerun` true for the commands that make something.

- The Topic that `topic new` makes for a Request has the Request id as its id. A second run finds the record with that id and makes no new Topic and no `-2` slug.
- `topic add-session --name <name>` gives the Session the exact name `<name>/<slug>`. When the Topic has a live Session with that name, the command finds it. When the record has the Session and tmux does not, the command makes the tmux Session from the record. When a Session outside the Topic has the name, the command refuses with `duplicate_session`. Without `--name`, the Session's name gets `+2` on a second run, so the policy is `inDoubt`. With `--worktree`, only the first run can type the Worktree's setup into the Session, so the policy is `inDoubt`.

## A command that writes no record has no `started` row

`window new`, `session new`, the two renames, `window zoom` and the kills change only tmux. No record write happens, so no transaction can hold a `started` row. Their row appears only as `done`. If the process ends in the middle, there is no row, and a second send runs the command as a first send does. For `window new` that can make a second Window. Phase 4 of the phone's work guards `window new`.

## One id runs in one process at a time

The phone can send again on a new connection while the first command still runs. Before the command line reads the row, it takes an exclusive `flock` on `<state folder>/requests/<id>.lock`, and it holds the lock until the answer is in the ledger. The second send waits, and then finds the `done` row. The command line removes a lock file only when the file is older than 24 hours and no process holds it. After it takes a lock, it checks that the path still names the same file.

## What the ledger keeps

The ledger keeps a success, and it keeps a refusal. A refusal is a failure with the phase `nothing_changed` and a kind on a fixed list (`TopicFailure.refusalKinds`): the Host looked at the request and at its own state and said no, as for a Tag that the Config does not define or a Topic that is not there. A second send gets the same refusal, also when the state changed in between.

The ledger keeps nothing else: `store_busy`, `store_failed`, `tmux_failed`, `git_failed`, `hook_failed`, an error before the request reaches the service, a kind that is not on the list, and each failure with another phase. `source_unavailable` and `topic_empty` are not on the list, because a tmux server that does not run gives them too. The default is to keep nothing. A refusal that runs again applies nothing twice, but a kept failure would stop the Request for 24 hours.

## A read refuses `--request`

`--request` goes anywhere before `--`. `CLICommand` takes it from the command line before the verb reads its words, and an id that is not a UUID is a usage error. A verb that changes nothing refuses the option with exit status 2 and names itself: the Topic reads, `environment show`, `worktree list`, and each verb that sends no request to the Environment, such as the Browser and Agent verbs. The option promises that the change applies one time. `topic exec` is a read for Muxify, but it runs a command, and to ignore the option there would break the promise without a word.

## The capability

`muxify environment show --json` has a key `capabilities` at the top of its object, a list of strings. This command line gives `["request"]`. The app-bundle CLI on a Mac can be older than the phone, so the phone sends `--request` only when the list has `request`. The key is in the command line's output only, not in `EnvironmentSnapshot`.

## Considered Options

- **Make each write idempotent by itself, with no ledger.** Rejected: a move of one place and a trade have no end state that a second run can find.
- **Keep a hash of the arguments.** Rejected: the text compares exactly, the Linux build needs no hash library, and a row lives 24 hours in a local file.
- **Keep the response as JSON and print it again.** Rejected: the text output and the `--json` output would each need a second printer that must give the same bytes.
- **A read ignores `--request`.** Rejected, as the section on reads says.
- **A `started` row for a command that changes only tmux, written before tmux runs.** Rejected: the row would say that something changed when nothing did, and each such command would then be in doubt after a failure that changed nothing.
- **A protocol number in `environment show`.** Rejected: a list of names lets a later option be added without a rule for which number includes which option.

## Consequences

- Exit status 3 is a Request id with other arguments. Exit status 4 is a Request in doubt. 1 and 2 keep their meaning.
- `EnvironmentService` and `TopicStore` take an optional `PendingRequest`. Only the command line gives one.
- `topic add-session` has a new option, `--name`, which also works without `--request`.
- A command without `--request` prints through the same code as before and reads no ledger.
- A refusal stays for 24 hours for its id. The phone must use a new id for each new action of the user.
- A row and its lock file stay for 24 hours, then the next ledger write and the next lock remove them.
