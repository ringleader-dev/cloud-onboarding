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

## When you change it

- **Keep each comment in the CloudFormation and ARM templates to one line.** A comment is part of
  the template a customer deploys, and templates have size limits. `deploy.sh` can deploy
  `aws/cloudformation/ringleader-onboarding.yaml` only when the template it renders is 51,200 bytes
  or less, and CI fails above that (`.github/scripts/check_template_size.py`). Put the reason a
  parameter, statement or resource has its shape in the `README.md` beside the template, or in the
  cloud's own `README.md`.
- **Describe what the repository does now, not how it got here.** Leave out earlier designs, what a
  value used to be, and why an old approach was dropped. The git log holds that history, so anyone
  who needs it can read it there.
