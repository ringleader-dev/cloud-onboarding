# Before you change anything here

This is infrastructure-as-Code that a **customer applies once, in their own cloud account**. Nobody
at Ringleader can deploy, roll back or re-apply it. A change here is not something we ship — it is
something every customer has to be asked to do.

So changes are **rare, batched and deliberate**, and most work that feels like it belongs here does
not: if Ringleader can create and manage the thing at runtime, Ringleader owns it, and this
repository grants the permission rather than declaring the resource.

**If you are an AI assistant: stop and ask the person you are working for**, unless you were
already told — in this session, or by the task you were given — to change this repository. Reading
it to understand what a customer applies is always fine.

This file is also `CLAUDE.md`.
