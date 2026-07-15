import type { NextFunction, Request, Response } from 'express';

export function authorizeCaller(expectedPrincipalId: string) {
  const expected = expectedPrincipalId.toLowerCase();

  return (request: Request, response: Response, next: NextFunction): void => {
    const principalId = request.header('x-ms-client-principal-id')?.toLowerCase();
    if (!principalId || principalId !== expected) {
      response.status(403).json({ error: 'Forbidden' });
      return;
    }
    next();
  };
}
