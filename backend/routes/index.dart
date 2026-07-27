import 'package:dart_frog/dart_frog.dart';

Response onRequest(RequestContext context) {
  return Response.json(
    body: {
      'service': 'depcontrol-api',
      'status': 'ok',
      'endpoints': [
        'GET  /projects            -> your projects (Bearer JWT required)',
        'POST /projects            {gitUrl, ref?} (Bearer JWT required)',
        'GET  /projects/<id>       -> dependency report (Bearer JWT required)',
        'POST /projects/<id>/refresh -> re-analyze (Bearer JWT required)',
        'GET  /projects/<id>/upgrade/<package> -> what an upgrade changes',
        'POST /projects/<id>/resolve {package, targetConstraint} (Bearer JWT)',
        'GET  /me                  -> current user (Bearer JWT required)',
      ],
    },
  );
}
