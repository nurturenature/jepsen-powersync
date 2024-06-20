## Usage

Use of symlinks can be problematic with GitHub and Docker's context and COPY.
So `.env` in the project root is duplicated. Update:
- `/project/.env`
- `/project/docker/.env`
- `/project/endpoint/.env`

synchronously.

The Docker environment is the easiest way to run tests.
The tests are designed to be re-runnable without having to recreate the containers and volumes.
