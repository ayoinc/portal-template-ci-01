import { render, screen } from '@testing-library/react';
import Home from '@/app/page';
import site from '@/site.json';

describe('Home page', () => {
  it('shows the application name as the heading', () => {
    render(<Home />);
    expect(
      screen.getByRole('heading', { level: 1, name: site.name }),
    ).toBeInTheDocument();
  });

  it('links to the health endpoint', () => {
    render(<Home />);
    expect(screen.getByRole('link', { name: 'Health Check' })).toHaveAttribute(
      'href',
      '/api/health',
    );
  });
});
