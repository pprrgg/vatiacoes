// Comunidades energeticas del IDAE publicadas como JSON (/data/comunidades-idae.json): la API
// de la plataforma comprueba con ellas que el alta online es de una comunidad del mapa.
import IDAE from '../../data/comunidades-idae.json';

export function GET() {
  return new Response(JSON.stringify(IDAE), { headers: { 'Content-Type': 'application/json; charset=utf-8' } });
}
