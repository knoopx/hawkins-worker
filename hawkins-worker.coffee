Firebase = require("firebase")
Stream = require('stream')
child_process = require("child_process")
optimist = require('optimist')
fs = require('fs')

process.title = 'Hawkins Worker'

{argv} = optimist.usage('Usage: hawkins-worker --firebase URL')
.options('firebase', {
    alias: 'f',
    describe: "Firebase URL",
  })
.options('help', {
    alias: "h",
    describe: "Show this message"
  })
.options('version', {
    alias: 'v',
    describe: "Show version"
  })

if argv.help
  optimist.showHelp()
  process.exit 0

unless argv.firebase?
  console.log("Missing --firebase")
  process.exit 1

Pushes = new Firebase(argv.firebase).child("pushes")
Builds = new Firebase(argv.firebase).child("builds")
Logs = new Firebase(argv.firebase).child("logs")

class Worker
  constructor: (queueRef, @callback) ->
    @busy = false
    queueRef.limitToFirst(1).on "child_added", (snap) =>
      @currentItem = snap.ref()
      @pop()

  pop: ->
    if not @busy and @currentItem
      @busy = true
      dataToProcess = null
      toProcess = @currentItem
      @currentItem = null
      toProcess.transaction ((job) ->
        dataToProcess = job
        if job
          null
        else
          return
      ), (error, committed) =>
        throw error if error
        if committed
          @callback dataToProcess, =>
            @busy = false
            @pop()
        else
          @busy = false
          @pop()

new Worker Pushes, (push, processNext) ->
  return unless push.pusher?

  build =
    repository: push.repository,
    branch: push.ref.replace(/^refs\/heads\//, "")
    commit: push.head_commit,
    status: "running",
    startedAt: Date.now()
    push: push

  buildRef = Builds.ref().push(build)

  buildKey = buildRef.key()
  log = Logs.child(buildKey)

  output = new Stream.Writable()
  output.write = (data) ->
    process.stdout.write(data)
    log.ref().push(data.toString())

  extend = require('util')._extend

  env = extend({}, process.env)
  extend(env,
    HAWKINS_BUILD: buildKey
    HAWKINS_BRANCH: build.branch
    HAWKINS_REVISION: build.commit.id
    HAWKINS_REPOSITORY_URL: build.repository.ssh_url
    HAWKINS_REPOSITORY_NAME: build.repository.name
  )

  runner = child_process.spawn "scripts/runner", [], env: env
  runner.stdout.pipe(output)
  runner.stderr.pipe(output)

  runner.on "exit", (exitCode) ->
    buildRef.child("finishedAt").ref().set(Date.now())
    if exitCode == 0
      buildRef.child("status").ref().set("success")
    else
      buildRef.child("status").ref().set("failed")

    processNext()
