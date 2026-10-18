// The stock stimulus-rails loader: registers every controllers/*_controller
// pin in the importmap, the engine's controllers/chats/* included.
import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"

eagerLoadControllersFrom("controllers", application)
